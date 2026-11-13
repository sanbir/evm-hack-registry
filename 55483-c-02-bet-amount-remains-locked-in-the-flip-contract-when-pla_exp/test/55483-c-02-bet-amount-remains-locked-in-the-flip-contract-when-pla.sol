// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Coinflip Flip win settlement (Pashov, 55483).
   Cheatcode-free reduction of the published win path. A 100 token bet at a
   10% fee forwards only the 10 fee. 90 stays in Flip. Staking still pays 190.
   The fix forwards betAmount - managerFee. The win is forced so the
   settlement path runs; the bug is the fee split, not the coin outcome. */

contract BetToken {
    string public name = "Bet";
    string public symbol = "BET";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingPool {
    BetToken public token;
    mapping(address => bool) public authorized;

    constructor(BetToken t) {
        token = t;
    }

    function authorize(address game) external {
        authorized[game] = true;
    }

    function transferPayout(address recipient, uint256 amount) external {
        require(authorized[msg.sender], "auth");
        require(token.transfer(recipient, amount), "payout");
    }
}

contract Flip {
    BetToken public token;
    StakingPool public staking;
    address public manager;
    bool public immutable fixedForward;
    uint256 public constant BET = 100 ether;
    uint256 public constant FEE_BPS = 1000;
    uint256 public constant BPS = 10000;
    uint256 public lastLocked;

    constructor(BetToken t, StakingPool s, address m, bool fix) {
        token = t;
        staking = s;
        manager = m;
        fixedForward = fix;
    }

    function bet() external {
        require(token.transferFrom(msg.sender, address(this), BET), "bet");
    }

    function resolveWin() external returns (uint256 locked) {
        uint256 betAmount = BET;
        uint256 fee = (betAmount * FEE_BPS) / BPS;
        uint256 grossPayout = betAmount * 2;
        uint256 netPayout = grossPayout - fee;
        staking.transferPayout(msg.sender, netPayout);
        uint256 managerFee = (fee * 0) / BPS;
        if (fixedForward) {
            uint256 stakingAmount = betAmount - managerFee;
            require(token.transfer(address(staking), stakingAmount), "full bet");
            locked = token.balanceOf(address(this));
        } else {
            // @> VULN: only the fee is forwarded; the rest of the bet stays here
            uint256 stakingFee = fee - managerFee;
            if (managerFee > 0) {
                require(token.transfer(manager, managerFee), "manager");
            }
            if (stakingFee > 0) {
                require(token.transfer(address(staking), stakingFee), "fee");
            }
            locked = token.balanceOf(address(this));
        }
        lastLocked = locked;
    }
}

contract Exploit {
    BetToken public token;
    StakingPool public staking;
    StakingPool public stakingFixed;
    Flip public flip;
    Flip public flipFixed;
    uint256 public locked;
    uint256 public lockedFixed;
    uint256 public stakingLeft;
    uint256 public stakingFixedLeft;

    constructor() {
        token = new BetToken();
        staking = new StakingPool(token);
        stakingFixed = new StakingPool(token);
        flip = new Flip(token, staking, address(0xA11CE), false);
        flipFixed = new Flip(token, stakingFixed, address(0xA11CE), true);
        staking.authorize(address(flip));
        stakingFixed.authorize(address(flipFixed));
        token.mint(address(staking), 1000 ether);
        token.mint(address(stakingFixed), 1000 ether);
        token.mint(address(this), 200 ether);
    }

    function run() external {
        token.approve(address(flip), 100 ether);
        flip.bet();
        locked = flip.resolveWin();
        stakingLeft = token.balanceOf(address(staking));
        require(locked == 90 ether, "locked");
        require(stakingLeft == 820 ether, "staking short 180");
        token.approve(address(flipFixed), 100 ether);
        flipFixed.bet();
        lockedFixed = flipFixed.resolveWin();
        stakingFixedLeft = token.balanceOf(address(stakingFixed));
        require(lockedFixed == 0, "fixed locked");
        require(stakingFixedLeft == 910 ether, "staking fair loss 90");
        require(stakingFixedLeft - stakingLeft == 90 ether, "extra loss");
    }
}
