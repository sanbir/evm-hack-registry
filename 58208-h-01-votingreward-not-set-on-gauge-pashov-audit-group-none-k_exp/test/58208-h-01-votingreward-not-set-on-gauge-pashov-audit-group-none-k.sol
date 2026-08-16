// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of KittenSwap finding 58208 (H-01):
// "`votingReward` not set on `Gauge`".
//
// Real audited source (Pashov Audit Group, KittenSwap security review 2025-06-12,
// report: github.com/pashov/audits/.../KittenSwap-security-review_2025-06-12.md).
// This finding is `embedded`: the ```solidity snippet quoted in the finding body
// IS the verbatim vulnerable source. The vulnerable line is marked @>:
//   contract Gauge  — fee-claim block inside `notifyRewardAmount()`
//
// Root cause: `Gauge.votingReward` is NEVER set during initialization and has no
// setter, so it stays `address(0)`. When `notifyRewardAmount()` claims fees from
// the pair and reaches the marked line, `votingReward.notifyRewardAmount(...)` is
// a high-level call to a zero-code address, which Solidity guards with an
// `extcodesize` check and reverts. Every fee-distribution attempt reverts
// identically, so claimed swap fees can NEVER be forwarded to the reward
// contract — they are permanently stuck until a brand-new Gauge is deployed.
//
// The vulnerable block is byte-for-byte the on-chain source. Non-vulnerable
// dependencies (the ERC20 token, the `IPair` fee source, the `IVotingReward`
// consumer that is supposed to receive fees) are faithful minimal doubles with
// real transfers and real accounting — the revert emerges from the verbatim
// code, it is not asserted.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev ERC20 subset the vulnerable block interacts with (approve) + the pair
///      double uses (transfer/balanceOf). Verbatim call sites use `IERC20(...)`.
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev The pair (LP token) interface used verbatim on the vulnerable lines.
interface IPair {
    function claimFees() external returns (uint256 claimed0, uint256 claimed1);
    function tokens() external view returns (address, address);
}

/// @dev The voting-reward (internal bribe / fees) consumer. `Gauge.votingReward`
///      is declared with this type but is never initialized -> address(0).
interface IVotingReward {
    function notifyRewardAmount(address token, uint256 amount) external;
}

/// @dev Faithful minimal ERC20 double (real transfers / real accounting).
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n_, string memory s_) {
        name = n_;
        symbol = s_;
    }

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

/// @dev Faithful double of the AMM pair. Swap fees accrue in the pair; on
///      `claimFees()` the accrued fees are transferred to the caller (the Gauge)
///      and the amounts are returned, exactly as a Solidly/Velodrome pair does.
contract Pair {
    address public token0;
    address public token1;
    uint256 public fees0;
    uint256 public fees1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    /// @notice accrue swap fees available to be claimed by the gauge
    function setFees(uint256 f0, uint256 f1) external {
        fees0 = f0;
        fees1 = f1;
    }

    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        claimed0 = fees0;
        claimed1 = fees1;
        fees0 = 0;
        fees1 = 0;
        if (claimed0 > 0) IERC20(token0).transfer(msg.sender, claimed0);
        if (claimed1 > 0) IERC20(token1).transfer(msg.sender, claimed1);
    }

    function tokens() external view returns (address, address) {
        return (token0, token1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the KittenSwap `Gauge`. `votingReward` is never set on
// initialization and there is no setter, so it is address(0). The fee-claim
// block inside `notifyRewardAmount()` is reproduced VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract Gauge {
    IERC20 public lpToken;
    IVotingReward public votingReward; // never set on init, no setter -> address(0)

    constructor(address _lpToken) {
        lpToken = IERC20(_lpToken);
        // NOTE (root cause): votingReward is NOT assigned here, and the contract
        //                    exposes no setter, so it remains address(0) forever.
    }

    /// @notice Distribute rewards; KittenSwap first claims the pair's swap fees
    ///         and forwards them to `votingReward`. The block below is VERBATIM
    ///         from the audited source (finding 58208).
    function notifyRewardAmount() external {
        uint256 claimed0;
        uint256 claimed1;
        (claimed0, claimed1) = IPair(address(lpToken)).claimFees();
        (address _token0, address _token1) = IPair(address(lpToken)).tokens();
        if (claimed0 > 0) {
            IERC20(_token0).approve(address(votingReward), claimed0);
            votingReward.notifyRewardAmount(_token0, claimed0); // @> VULN: votingReward is unset (address(0)) with no setter, so this high-level call to a zero-code address reverts (extcodesize check), permanently blocking fee distribution
        }
        if (claimed1 > 0) {
            IERC20(_token1).approve(address(votingReward), claimed1);
            votingReward.notifyRewardAmount(_token1, claimed1);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: accrue swap fees in the pair, then show that every attempt to
// distribute them via `Gauge.notifyRewardAmount()` reverts (votingReward unset),
// leaving the fees permanently stuck in the pair. The stuck-fee magnitude is
// minted to SINK on a marker token to record the DoS harm (no attacker profit).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // DoS harm has no positive transfer to an attacker; the harm magnitude
    // (fees that can never be distributed) is recorded at this sink address.
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniToken public token0;
    MiniToken public token1;
    Pair public pair;
    Gauge public vuln;
    MiniToken public marker;

    uint256 public constant FEES = 100e18; // swap fees accrued in the pair

    bool public notifyReverted; // proves the DoS
    uint256 public stuckFees; // fees still trapped in the pair after the attempt

    constructor() {
        token0 = new MiniToken("KittenSwap Token0", "TK0"); // child nonce 1
        token1 = new MiniToken("KittenSwap Token1", "TK1"); // child nonce 2
        pair = new Pair(address(token0), address(token1)); // child nonce 3
        vuln = new Gauge(address(pair)); // child nonce 4 (VULN)
        marker = new MiniToken("StuckFees", "STUCK"); // child nonce 5 (marker/profit)
    }

    function run() external {
        // swap fees accrue in the pair, ready to be claimed by the gauge
        token0.mint(address(pair), FEES);
        pair.setFees(FEES, 0);

        uint256 pairBefore = token0.balanceOf(address(pair));

        // Attempt to distribute fees. Because votingReward is address(0), the
        // verbatim vulnerable line reverts; the whole tx (including claimFees)
        // rolls back, so the fees never leave the pair.
        try vuln.notifyRewardAmount() {
            notifyReverted = false;
        } catch {
            notifyReverted = true;
        }

        // fees are still stuck in the pair — distribution is permanently blocked
        stuckFees = token0.balanceOf(address(pair));

        // record the DoS harm magnitude at the sink (no attacker profit)
        marker.mint(SINK, stuckFees);

        // HARM: fee distribution reverts and the swap fees are permanently stuck
        require(notifyReverted, "notifyRewardAmount did not revert - votingReward call succeeded");
        require(stuckFees == pairBefore, "fees were not stuck (some distribution happened)");
        require(marker.balanceOf(SINK) == FEES, "harm magnitude not recorded");
    }
}
