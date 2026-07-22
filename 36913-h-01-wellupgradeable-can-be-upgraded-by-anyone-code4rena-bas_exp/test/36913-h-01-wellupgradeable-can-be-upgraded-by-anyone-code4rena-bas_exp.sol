// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "./36913-h-01-wellupgradeable-can-be-upgraded-by-anyone-code4rena-bas.sol";

contract WellUpgradeableExpTest is Test {
    function test_anyone_can_upgrade_the_well_proxy() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(
            WellUpgradeable(address(e.proxy())).getImplementation(),
            e.well2Clone(),
            "the proxy must now be running the attacker-chosen implementation"
        );
    }

    /// @dev Control: with the recommended `onlyOwner` fix applied, the exact
    ///      same unauthorized call must revert instead of succeeding.
    function test_control_fixed_version_reverts_for_non_owner() public {
        Aquifer aquifer = new Aquifer();
        WellUpgradeableFixed impl1 = new WellUpgradeableFixed(aquifer, address(this));
        address well1Clone = aquifer.boreWell(address(impl1));
        FixedProxy proxy = new FixedProxy(well1Clone);

        WellUpgradeableFixed impl2 = new WellUpgradeableFixed(aquifer, address(this));
        address well2Clone = aquifer.boreWell(address(impl2));

        RandomAttackerFixed attacker = new RandomAttackerFixed();
        vm.expectRevert("Not owner");
        attacker.steal(address(proxy), well2Clone);
    }
}

/// @dev Standalone patched analog used only by the control test: same
///      structure as `WellUpgradeable`, but `_authorizeUpgrade` adds the
///      recommended `onlyOwner` restriction (the finding's exact fix).
contract WellUpgradeableFixed {
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x0360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bb;
    address private immutable ___self = address(this);
    IAquifer public immutable aquiferOf;
    address public immutable owner;

    constructor(IAquifer _aquifer, address _owner) {
        aquiferOf = _aquifer;
        owner = _owner;
    }

    function aquifer() public view returns (address) {
        return address(aquiferOf);
    }

    function _getImplementation() internal view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    function _authorizeUpgrade(address newImplmentation) internal view {
        require(msg.sender == owner, "Not owner"); // FIX applied: onlyOwner
        require(address(this) != ___self, "Function must be called through delegatecall");
        address activeProxy = IAquifer(aquifer()).wellImplementation(_getImplementation());
        require(activeProxy == ___self, "Function must be called through active proxy bored by an aquifer");
        require(
            IAquifer(aquifer()).wellImplementation(newImplmentation) != address(0),
            "New implementation must be a well implmentation"
        );
        require(
            WellUpgradeableFixed(newImplmentation).proxiableUUID() == _IMPLEMENTATION_SLOT,
            "New implementation must be a valid ERC-1967 implmentation"
        );
    }

    function upgradeTo(address newImplementation) public {
        _authorizeUpgrade(newImplementation);
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
    }

    function proxiableUUID() external pure returns (bytes32) {
        return _IMPLEMENTATION_SLOT;
    }
}

contract FixedProxy {
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x0360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bb;

    constructor(address logic) {
        assembly {
            sstore(_IMPLEMENTATION_SLOT, logic)
        }
    }

    fallback() external payable {
        address impl;
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
        (bool ok, bytes memory ret) = impl.delegatecall(msg.data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}

contract RandomAttackerFixed {
    function steal(address proxy, address newImplementation) external {
        WellUpgradeableFixed(proxy).upgradeTo(newImplementation);
    }
}
