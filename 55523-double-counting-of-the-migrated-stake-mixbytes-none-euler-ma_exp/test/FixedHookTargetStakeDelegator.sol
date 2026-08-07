// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// NEGATIVE CONTROL ONLY — this is NOT audited source.
// It is a byte-for-byte copy of the audited HookTargetStakeDelegator with the
// SINGLE fix recommended by MixBytes applied to `_delegateStake` (migrate first,
// then delegate only the NEW `amount`, so the migrated stake is not double-counted).
// Used solely to prove the harm disappears once the double-count is removed.

import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {ProtocolConfig} from "evk/ProtocolConfig/ProtocolConfig.sol";
import {IHookTarget} from "evk/interfaces/IHookTarget.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";

// Reuse the audited helper token + interfaces from the real source file.
import {
    ERC20ShareRepresentation,
    IRewardVault,
    IRewardVaultFactory
} from "../src/HookTarget/HookTargetStakeDelegator.sol";

contract HookTargetStakeDelegatorFixed is Ownable, IHookTarget {
    using EnumerableSet for EnumerableSet.AddressSet;

    IEVC public immutable evc;
    IEVault public immutable eVault;
    ERC20ShareRepresentation public immutable erc20;
    IRewardVault public immutable rewardVault;

    EnumerableSet.AddressSet internal touchedAccounts;
    mapping(address account => uint256 amount) internal initialBalances;

    constructor(address _eVault, address _rewardVaultFactory) Ownable(_eVault) {
        evc = IEVC(IEVault(_eVault).EVC());
        eVault = IEVault(_eVault);
        erc20 = new ERC20ShareRepresentation(_eVault);
        rewardVault = IRewardVault(IRewardVaultFactory(_rewardVaultFactory).predictRewardVaultAddress(address(erc20)));
        erc20.approve(address(rewardVault), type(uint256).max);
    }

    function deposit(uint256, address receiver) external onlyOwner returns (uint256) {
        _snapshotAccount(receiver);
        return 0;
    }

    function checkVaultStatus() external onlyOwner returns (bytes4) {
        address[] memory accounts = touchedAccounts.values();
        for (uint256 i = 0; i < accounts.length; ++i) {
            address account = accounts[i];
            uint256 initialBalance = initialBalances[account];
            uint256 currentBalance = eVault.balanceOf(account);
            if (currentBalance > initialBalance) {
                uint256 amount = currentBalance - initialBalance;
                erc20.mint(amount);
                _delegateStake(account, amount);
            } else if (currentBalance < initialBalance) {
                uint256 amount = initialBalance - currentBalance;
                erc20.burn(_delegateWithdraw(account, amount));
            }
            initialBalances[account] = 0;
            touchedAccounts.remove(account);
        }
        return 0;
    }

    function isHookTarget() external view override returns (bytes4) {
        if (address(rewardVault).code.length == 0) return 0;
        return this.isHookTarget.selector;
    }

    function _snapshotAccount(address account) internal {
        if (touchedAccounts.add(account)) {
            initialBalances[account] = eVault.balanceOf(account);
        }
    }

    // ===== THE FIX (MixBytes recommendation) =====
    // Original (vulnerable):
    //   rewardVault.delegateStake(owner == address(0) ? account : owner, amount + _migrateStake(owner, account));
    // Fixed: migrate first, then delegate only the NEW amount.
    function _delegateStake(address account, uint256 amount) internal {
        address owner = evc.getAccountOwner(account);
        _migrateStake(owner, account);
        rewardVault.delegateStake(owner == address(0) ? account : owner, amount);
    }

    function _delegateWithdraw(address account, uint256 amount) internal returns (uint256) {
        address owner = evc.getAccountOwner(account);
        _migrateStake(owner, account);
        if (owner == address(0)) owner = account;
        uint256 stake = rewardVault.getDelegateStake(owner, address(this));
        if (amount > stake) amount = stake;
        if (amount > 0) rewardVault.delegateWithdraw(owner, amount);
        return amount;
    }

    function _migrateStake(address owner, address account) internal returns (uint256) {
        uint256 stake;
        if (owner != address(0) && owner != account) {
            stake = rewardVault.getDelegateStake(account, address(this));
            if (stake > 0) {
                rewardVault.delegateWithdraw(account, stake);
                rewardVault.delegateStake(owner, stake);
            }
        }
        return stake;
    }
}
