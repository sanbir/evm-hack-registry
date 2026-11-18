// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Dumont — the 80% burn fee is sent only when the player wins
    (Pashov H-01, finding 38015). SYNTHETIC, cheatcode-free.
    A 1000 USDT losing bet owes the burner 80 USDT. The transfer sits inside
    the winner branch, so the burner receives 0 while the player is still
    minted 100 MONT. The 80 USDT stays in the vault. (@> VULN) */

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Burner {}

contract Vault {
    MockToken public usdt;
    MockToken public mont;
    Burner public burner;
    uint256 public bet;
    uint256 public pendingBurn;
    bool public winnerBranchTaken;

    constructor(MockToken u, MockToken m, Burner b) {
        usdt = u;
        mont = m;
        burner = b;
    }

    function transferPlayerRewards(bool _isPlayerWinner, uint256 _totalAmount, address player) external {
        pendingBurn = (1000e6 / 10) * 8 / 10; // S2 80 USDT, 80% of the 10% fee on a 1000 USDT bet
        bet = 1000e6;
        if (_isPlayerWinner) { // @> VULN: the burner transfer is inside this branch, so a losing bet sends 0
            // FIX: usdt.transfer(address(burner), pendingBurn) before the winner check
            winnerBranchTaken = true;
            usdt.transfer(player, _totalAmount);
            usdt.transfer(address(burner), pendingBurn);
        }
        mont.mint(player, 100 ether); // S4 MONT rewards are still paid on a loss
    }
}

contract Exploit {
    MockToken public usdt; // nonce 1
    MockToken public mont; // nonce 2
    Burner public burner; // nonce 3
    Vault public vault; // nonce 4

    constructor() {
        usdt = new MockToken();
        mont = new MockToken();
        burner = new Burner();
        vault = new Vault(usdt, mont, burner);
        usdt.mint(address(vault), 1000e6);
    }

    function run() external {
        vault.transferPlayerRewards(false, 0, address(this)); // S1 losing game
        uint256 burnerBal = usdt.balanceOf(address(burner)); // S5
        uint256 montBal = mont.balanceOf(address(this)); // S6
        require(vault.pendingBurn() == 80e6, "owed 80");
        require(burnerBal == 0, "burner received nothing");
        require(montBal == 100 ether, "MONT still minted");
        require(usdt.balanceOf(address(vault)) == 1000e6, "80 USDT fee never left the vault");
        require(vault.winnerBranchTaken() == false, "loss took the winner branch");
    }
}
