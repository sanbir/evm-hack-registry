// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  VTVL BaseMilestone — onlyDeposited locks the remainder
    (OtterSec, Robert Chen, finding #47910)
    SYNTHETIC, cheatcode-free. The modifier is the audited check:
    balance >= allocation * recipients.length. After one recipient
    withdraws, the balance falls below that constant and the other
    recipient's tokens cannot be released. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Recipient {}

contract BaseMilestone {
    MockToken public tokenAddress;
    uint256 public allocation;
    address[] public recipients;
    mapping(address => bool) public isComplete;
    mapping(address => bool) public hasWithdrawn;
    uint256 public totalWithdrawnAmount;
    bool public bobRejected;

    error NotDeposited();
    error AlreadyCompleted();
    error NotComplete();
    error AlreadyWithdrawn();

    constructor(MockToken token_, uint256 allocation_, address[] memory recipients_) {
        tokenAddress = token_;
        allocation = allocation_;
        for (uint256 i = 0; i < recipients_.length; ++i) {
            recipients.push(recipients_[i]);
        }
    }

    modifier onlyDeposited() {
        uint256 balance = tokenAddress.balanceOf(address(this));
        // @> VULN: live balance is compared to the original full allocation, which ignores withdrawals
        require(balance >= allocation * recipients.length, "NOT_DEPOSITED");
        // FIX: require(balance + totalWithdrawnAmount >= allocation * recipients.length, "NOT_DEPOSITED");
        _;
    }

    function setComplete(address recipient_) external onlyDeposited {
        if (isComplete[recipient_]) revert AlreadyCompleted();
        isComplete[recipient_] = true;
    }

    /// Fix from the report: count tokens already paid out, so the remainder can still be completed.
    function setCompleteFixed(address recipient_) external {
        uint256 balance = tokenAddress.balanceOf(address(this));
        uint256 covered = balance + totalWithdrawnAmount;
        require(covered >= allocation * recipients.length, "NOT_DEPOSITED");
        if (isComplete[recipient_]) revert AlreadyCompleted();
        isComplete[recipient_] = true;
    }

    function withdraw(address recipient_) external {
        if (!isComplete[recipient_]) revert NotComplete();
        if (hasWithdrawn[recipient_]) revert AlreadyWithdrawn();
        hasWithdrawn[recipient_] = true;
        totalWithdrawnAmount += allocation;
        tokenAddress.transfer(recipient_, allocation);
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }
}

contract Exploit {
    MockToken public token; // CREATE nonce 1
    Recipient public alice; // CREATE nonce 2
    Recipient public bob; // CREATE nonce 3
    BaseMilestone public milestone; // CREATE nonce 4
    uint256 public constant ALLOCATION = 100 ether;

    constructor() {
        token = new MockToken("VTVL", "VTVL", 18);
        alice = new Recipient();
        bob = new Recipient();
        address[] memory who = new address[](2);
        who[0] = address(alice);
        who[1] = address(bob);
        milestone = new BaseMilestone(token, ALLOCATION, who);
    }

    function run() external {
        uint256 full = ALLOCATION * 2;
        token.mint(address(this), full);
        token.transfer(address(milestone), full);
        milestone.setComplete(address(alice));
        milestone.withdraw(address(alice));
        bool bobOpened = true;
        try milestone.setComplete(address(bob)) {
            bobOpened = true;
        } catch {
            bobOpened = false;
        }
        uint256 stuck = token.balanceOf(address(milestone));
        uint256 paid = token.balanceOf(address(alice));
        require(bobOpened == false, "bob was not locked");
        require(stuck == ALLOCATION, "stuck amount");
        require(paid == ALLOCATION, "alice paid");
        require(milestone.isComplete(address(bob)) == false, "bob complete");
    }
}
