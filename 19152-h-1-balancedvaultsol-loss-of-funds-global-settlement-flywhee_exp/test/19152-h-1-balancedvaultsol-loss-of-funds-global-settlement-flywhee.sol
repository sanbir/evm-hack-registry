// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Perennial BalancedVault — a second stale deposit overwrites _pendingEpochs
    (Sherlock 2023-05, finding 19152, BalancedVault.deposit).

    SYNTHETIC, cheatcode-free. Epochs advance inside settleGlobal. No warp.
    The user queues 100e18 while epoch 1 is stale, so it is processed by the
    global flywheel at the epoch-3 price of 1. A 1e18 deposit in stale epoch 2
    sets _pendingEpochs to 3, so the user flywheel waits until epoch 4, when
    the price is 2. The user is minted 50.5e18 shares against 100.5e18 shares
    on the global side. The gap is 50e18.

    The control keeps the earlier pending epoch. The user is minted at the
    epoch-3 price and is not short those 50e18 shares. */

contract BalancedVault {
    uint256 public epoch = 1;
    bool public stale;

    uint256 public _pendingDeposit;
    uint256 public _deposit;
    uint256 public _totalSupply;
    uint256 public lastPushed;

    mapping(address => uint256) public _pendingDeposits;
    mapping(address => uint256) public _pendingEpochs;
    mapping(address => uint256) public _balanceOf;

    function markStale() external {
        stale = true;
    }

    function deposit(uint256 assets, address account) external {
        if (stale) {
            _pendingDeposit += assets;
            _pendingDeposits[account] += assets;
            _setPendingEpoch(account);
        } else {
            _deposit += assets;
            _pendingEpochs[account] = epoch;
        }
    }

    function _setPendingEpoch(address account) internal virtual {
        uint256 scheduled = epoch + 1;
        if (_pendingEpochs[account] != 0) {
            this.pushPendingEpoch(account, scheduled);
        } else {
            _pendingEpochs[account] = scheduled;
        }
    }

    function pushPendingEpoch(address account, uint256 scheduled) external {
        require(msg.sender == address(this), "only self");
        // @> VULN: a later stale deposit overwrites _pendingEpochs and pushes user settlement past the global mint.
        lastPushed = scheduled;
        _pendingEpochs[account] = scheduled;
        // FIX: keep an earlier pending epoch. Do not move it further out.
    }

    function settleGlobal() public {
        epoch += 1;
        uint256 price = epoch >= 4 ? 2 ether : 1 ether;
        if (_deposit > 0) {
            _totalSupply += _toShares(_deposit, price);
            _deposit = 0;
        }
        _deposit = _pendingDeposit;
        _pendingDeposit = 0;
        stale = false;
    }

    function settleAccount(address account) public {
        if (_pendingEpochs[account] != 0 && epoch > _pendingEpochs[account]) {
            uint256 price = epoch >= 4 ? 2 ether : 1 ether;
            _balanceOf[account] += _toShares(_pendingDeposits[account], price);
            _pendingDeposits[account] = 0;
            _pendingEpochs[account] = 0;
        }
    }

    function _toShares(uint256 assets, uint256 price) internal pure returns (uint256) {
        return assets * 1 ether / price;
    }
}

contract BalancedVaultFixed is BalancedVault {
    function _setPendingEpoch(address account) internal override {
        uint256 next = epoch + 1;
        if (_pendingEpochs[account] == 0 || next < _pendingEpochs[account]) {
            _pendingEpochs[account] = next;
        }
    }
}

contract Exploit {
    uint256 public constant MAIN = 100 ether;
    uint256 public constant DUST = 1 ether;
    uint256 public constant N = 50 ether;

    BalancedVault public vault;
    uint256 public supplyAfter;
    uint256 public sharesAfter;
    uint256 public loss;

    constructor() {
        vault = new BalancedVault();
    }

    function run() external {
        address user = address(this);
        vault.markStale();
        vault.deposit(MAIN, user);
        vault.settleGlobal();
        vault.markStale();
        vault.deposit(DUST, user);
        vault.settleGlobal();
        vault.settleAccount(user);
        vault.settleGlobal();
        vault.settleAccount(user);
        supplyAfter = vault._totalSupply();
        sharesAfter = vault._balanceOf(user);
        loss = supplyAfter - sharesAfter;
        require(vault._pendingEpochs(user) == 0, "user was not settled");
        require(sharesAfter == 50.5 ether, "user was not minted at the later price");
        require(supplyAfter == 100.5 ether, "global mint was not 100.5e18");
        require(loss == N, "harm");
    }
}
