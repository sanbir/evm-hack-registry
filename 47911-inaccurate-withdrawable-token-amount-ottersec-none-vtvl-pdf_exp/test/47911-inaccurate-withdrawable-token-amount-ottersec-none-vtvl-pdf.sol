// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  VTVL — Inaccurate Withdrawable Token Amount (OtterSec, finding 47911)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    withdrawAdmin uses allocation * recipients.length - numTokensReservedForVesting.
    That is 600 - 400 = 200. The token balance is 1000, so the fair unreserved
    amount is 1000 - 400 = 600. The owner receives 200 and 400 stays locked.
    The corrected withdraw sends balance - reserved. Vulnerable formula
    preserved verbatim (@> VULN). */

contract MockToken {
    string public name = "Vest";
    string public symbol = "VEST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function safeTransfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }
}

contract BaseMilestone {
    uint256 public allocation = 300 ether;
    uint256 public numTokensReservedForVesting = 400 ether;
    address public owner;
    MockToken public token;
    address[] public recipients;
    uint256 public lastWithdrawn;

    event AdminWithdrawn(address indexed admin, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(address token_) {
        token = MockToken(token_);
        owner = msg.sender;
        recipients.push(address(0xA11));
        recipients.push(address(0xB22));
    }

    function fairWithdrawable() public view returns (uint256) {
        return token.balanceOf(address(this)) - numTokensReservedForVesting;
    }

    // BaseMilestone.withdrawAdmin — formula quoted by the report.
    function withdrawAdmin() public onlyOwner returns (uint256 availableAmount) {
        // @> VULN: allocation * recipients.length ignores the real token balance, so surplus above that product stays locked
        availableAmount = allocation * recipients.length - numTokensReservedForVesting;
        // FIX: availableAmount = token.balanceOf(address(this)) - numTokensReservedForVesting
        token.safeTransfer(msg.sender, availableAmount);
        lastWithdrawn = availableAmount;
        emit AdminWithdrawn(msg.sender, availableAmount);
    }
}

contract BaseMilestoneFixed {
    uint256 public numTokensReservedForVesting = 400 ether;
    address public owner;
    MockToken public token;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(address token_) {
        token = MockToken(token_);
        owner = msg.sender;
    }

    function withdrawAdmin() public onlyOwner returns (uint256 availableAmount) {
        availableAmount = token.balanceOf(address(this)) - numTokensReservedForVesting;
        token.safeTransfer(msg.sender, availableAmount);
    }
}

contract Exploit {
    uint256 public constant BALANCE = 1000 ether;
    uint256 public constant RESERVED = 400 ether;
    uint256 public constant NOTIONAL = 600 ether;

    MockToken public token;
    BaseMilestone public milestone;
    uint256 public fair;
    uint256 public withdrawn;
    uint256 public leftBehind;

    constructor() {
        token = new MockToken();
        milestone = new BaseMilestone(address(token));
    }

    function run() external {
        token.mint(address(milestone), BALANCE);
        fair = milestone.fairWithdrawable();
        withdrawn = milestone.withdrawAdmin();
        leftBehind = token.balanceOf(address(milestone)) - RESERVED;
        require(milestone.recipients(0) != address(0), "no recipients");
        require(milestone.allocation() * 2 == NOTIONAL, "notional cap");
        require(fair == BALANCE - RESERVED, "fair is not 600");
        require(withdrawn == NOTIONAL - RESERVED, "withdrawn is not 200");
        require(withdrawn < fair, "owner did not receive less than fair");
        require(token.balanceOf(address(this)) == withdrawn, "owner balance");
        require(leftBehind == fair - withdrawn, "locked surplus is not 400");
    }
}
