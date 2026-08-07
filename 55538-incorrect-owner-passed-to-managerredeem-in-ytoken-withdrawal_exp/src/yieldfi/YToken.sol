// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {Constants} from "./Constants.sol";
import {IRole} from "./administrator/interface/IRole.sol";
import {IBlackList} from "./administrator/interface/IBlackList.sol";
import {IPausable} from "./administrator/interface/IPausable.sol";
import {IManager} from "./IManager.sol";

/// @dev YieldFi's `Access` base, byte-faithful to
/// github.com/YieldFiLabs/smart-contracts/contracts/administrator/Access.sol,
/// adapted from `ReentrancyGuardUpgradeable` to the non-upgradeable
/// `ReentrancyGuard` so it can be `new`-ed in a test (the audited YToken is an
/// upgradeable proxy; the withdrawal-owner bug is independent of upgradeability).
abstract contract Access is ReentrancyGuard {
    address public administrator;

    constructor(address _administrator) {
        require(_administrator != address(0), "!administrator");
        administrator = _administrator;
    }

    modifier onlyMinterAndRedeemer() {
        require(IRole(administrator).hasRole(Constants.MINTER_AND_REDEEMER_ROLE, msg.sender), "!minter");
        _;
    }

    modifier notPaused() {
        require(!IPausable(administrator).isPaused(address(this)), "paused");
        _;
    }
}

/// @notice YieldFi yToken, as audited at the deleted `YieldFiLabs/contracts`
/// commit 40caad6c, `contracts/core/tokens/YToken.sol`. The real base
/// (`ERC4626` + `Access`) is used; `_withdraw` below is reproduced VERBATIM from
/// the Cyfrin YieldFi v2.0 report (finding: "Incorrect `owner` passed to
/// `Manager::redeem` in YToken withdrawal flow").
///
/// VULNERABILITY (55538): `_withdraw` correctly spends `owner`'s allowance but
/// then tells the Manager the redeemer is `msg.sender` (the third-party caller),
/// not `owner`. During order execution the Manager burns `msg.sender`'s shares
/// instead of `owner`'s -> the delegated redemption reverts (caller has no
/// shares) or burns the WRONG account's tokens (caller happens to hold shares).
contract YToken is Access, ERC4626 {
    address public manager;

    constructor(IERC20 asset_, address administrator_, address manager_)
        ERC20("YieldFi yToken", "yUSD")
        ERC4626(asset_)
        Access(administrator_)
    {
        manager = manager_;
    }

    /// @dev The Manager (holding MINTER_AND_REDEEMER) burns the redeemer's shares
    /// when it executes a queued order. `"!balance"` is the exact revert the
    /// audit report's PoC observes for the delegated-withdrawal case.
    function managerBurn(address account, uint256 shares) external onlyMinterAndRedeemer {
        require(balanceOf(account) >= shares, "!balance");
        _burn(account, shares);
    }

    // ---- VERBATIM from the Cyfrin report (YToken.sol#L161-L172) ----
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
        nonReentrant
        notPaused
    {
        require(receiver != address(0) && owner != address(0) && assets > 0 && shares > 0, "!valid");
        require(
            !IBlackList(administrator).isBlackListed(caller) && !IBlackList(administrator).isBlackListed(receiver),
            "blacklisted"
        );
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        // Instead of burning shares here, just redirect to Manager
        // @audit-issue `msg.sender` passed as owner (should be `owner`)
        IManager(manager).redeem(msg.sender, address(this), asset(), shares, receiver, address(0), "");
    }
}

/// @notice The report's Recommended Mitigation: pass the correct `owner` to
/// `manager.redeem`. Used as the negative control.
contract YTokenFixed is YToken {
    constructor(IERC20 asset_, address administrator_, address manager_)
        YToken(asset_, administrator_, manager_)
    {}

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
        notPaused
    {
        require(receiver != address(0) && owner != address(0) && assets > 0 && shares > 0, "!valid");
        require(
            !IBlackList(administrator).isBlackListed(caller) && !IBlackList(administrator).isBlackListed(receiver),
            "blacklisted"
        );
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        // FIX: pass `owner` (not msg.sender)
        IManager(manager).redeem(owner, address(this), asset(), shares, receiver, address(0), "");
    }
}
