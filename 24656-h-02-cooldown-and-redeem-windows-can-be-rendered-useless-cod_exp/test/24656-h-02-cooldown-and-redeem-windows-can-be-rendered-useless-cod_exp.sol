// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "forge-std/Test.sol";
import {sNOTE} from "../src/sNOTE.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockVault {
    address public immutable pool;

    constructor(address pool_) {
        pool = pool_;
    }

    function getPool(bytes32) external view returns (address, IVault.PoolSpecialization) {
        return (pool, IVault.PoolSpecialization.TWO_TOKEN);
    }
}

contract DelegateProxy {
    address public immutable implementation;

    constructor(address implementation_) {
        implementation = implementation_;
    }

    fallback() external payable {
        address target = implementation;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract PoC_24656 is Test {
    MockToken private bpt;
    sNOTE private snote;
    address private attacker = address(0xA11CE);
    address private victim = address(0xB0B);

    function setUp() public {
        bpt = new MockToken();
        MockToken note = new MockToken();
        MockToken weth = new MockToken();
        MockVault vault = new MockVault(address(bpt));
        sNOTE implementation = new sNOTE(IVault(address(vault)), bytes32("NOTE-ETH"), note, weth);
        DelegateProxy proxy = new DelegateProxy(address(implementation));
        snote = sNOTE(address(proxy));
        snote.initialize(address(this), 1);

        bpt.mint(attacker, 1);
        bpt.mint(victim, 100 ether);
        vm.prank(attacker);
        bpt.approve(address(snote), type(uint256).max);
        vm.prank(victim);
        bpt.approve(address(snote), type(uint256).max);
    }

    function test_reported_empty_cooldown_path_is_rejected_by_snapshot() public {
        // The reported path starts an empty cooldown window before depositing.
        vm.prank(victim);
        snote.startCoolDown();
        vm.warp(block.timestamp + 2);

        // The exact contest source rejects a deposit while its redemption
        // window is active; the BPT transfer is rolled back with the revert.
        vm.expectRevert(bytes("Account in Cool Down"));
        vm.prank(victim);
        snote.mintFromBPT(100 ether);

        assertEq(bpt.balanceOf(victim), 100 ether);

        // Once the full redemption window has elapsed, a deposit is allowed,
        // but the old window is no longer valid for redeeming that deposit.
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(victim);
        snote.mintFromBPT(100 ether);

        vm.expectRevert(bytes("Not in Redemption Window"));
        vm.prank(victim);
        snote.redeem(100 ether);
    }
}
