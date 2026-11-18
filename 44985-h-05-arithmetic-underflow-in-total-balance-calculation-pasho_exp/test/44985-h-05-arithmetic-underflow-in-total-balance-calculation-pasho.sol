// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Nexus DepositETH — ethDeposited - ethWithdrawn + rewardsClaimed underflows
    (Pashov H-05, finding 44985). SYNTHETIC, cheatcode-free.
    Left-to-right subtraction reverts when ethWithdrawn exceeds ethDeposited,
    even though adding rewardsClaimed would make the balance positive.
    100 deposited, 150 withdrawn, 80 rewards => true balance 30. The update
    reverts, and withdraw reverts with it, so the 30 tokens stay put. (@> VULN) */

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; // S2
        balanceOf[to] += amount;
        return true;
    }
}

contract Holder {
    function withdraw(DepositETH dep, uint256 shares) external {
        dep.withdraw(shares);
    }
}

contract DepositETH {
    uint256 public constant BASE_POINT = 1e18;

    MockToken public token;
    uint256 public ethDeposited;
    uint256 public ethWithdrawn;
    uint256 public rewardsClaimed;
    uint256 public nETHMinted;
    uint256 public sharePrice;

    constructor(MockToken t) {
        token = t;
        ethDeposited = 100 ether;
        ethWithdrawn = 150 ether;
        nETHMinted = 100 ether;
    }

    function _updateSharePrice(uint256 _rewardsEarned) internal {
        rewardsClaimed += _rewardsEarned;
        uint256 totalEthBalance = (ethDeposited - ethWithdrawn + rewardsClaimed); // @> VULN: subtraction runs before rewards are added, so 100 - 150 reverts
        // FIX: uint256 totalEthBalance = ethDeposited + rewardsClaimed - ethWithdrawn;
        if (nETHMinted == 0) {
            sharePrice = BASE_POINT;
        } else {
            sharePrice = (nETHMinted) * BASE_POINT / (ethDeposited - ethWithdrawn + rewardsClaimed);
        }
        totalEthBalance;
    }

    function poke(uint256 rewards) external {
        _updateSharePrice(rewards);
    }

    function updateFixed(uint256 rewards) external {
        rewardsClaimed += rewards;
        uint256 totalEthBalance = ethDeposited + rewardsClaimed - ethWithdrawn;
        sharePrice = (nETHMinted) * BASE_POINT / totalEthBalance;
    }

    function withdraw(uint256 shares) external {
        require(shares > 0, "shares"); // S6
        _updateSharePrice(0);
        token.transfer(msg.sender, token.balanceOf(address(this)));
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    Holder public holder; // nonce 2
    DepositETH public dep; // nonce 3

    constructor() {
        token = new MockToken();
        holder = new Holder();
        dep = new DepositETH(token);
        token.mint(address(this), 30 ether);
    }

    function run() external {
        token.transfer(address(dep), 30 ether); // S1
        (bool pokeOk,) = address(dep).call(abi.encodeWithSignature("poke(uint256)", uint256(80 ether))); // S3
        (bool wdOk,) = address(holder).call(abi.encodeWithSignature("withdraw(address,uint256)", address(dep), uint256(1))); // S5
        require(!pokeOk, "update should revert");
        require(!wdOk, "withdraw should revert");
        require(token.balanceOf(address(dep)) == 30 ether, "30 locked");
        require(token.balanceOf(address(holder)) == 0, "holder received 0");
        require(dep.sharePrice() == 0, "price never updated");
    }
}
