// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*//////////////////////////////////////////////////////////////////////////
    f(x) v2 FlashLoans — honest repayment always reverts (OpenZeppelin, #61789)

    SYNTHETIC, cheatcode-free reduction. Verbatim check from FlashLoans.sol
    at 56a47eab (AladdinDAO/fx-protocol-contracts):

        prevBalance is sampled BEFORE the principal is sent.
        returnedAmount = balanceAfter - prevBalance
        which is only the surplus (the fee), then compared to amount + fee.

    An honest borrower who returns principal + fee still reverts
    ErrorInsufficientFlashLoanReturn. The audited fix samples prevBalance
    AFTER the transfer. No warp. One transaction.
//////////////////////////////////////////////////////////////////////////*/

contract Token {
    string public name = "fxUSD";
    string public symbol = "fxUSD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ArbDesk {
    Token public immutable token;

    constructor(Token t) {
        token = t;
    }

    function pay(address to, uint256 amt) external {
        require(token.transfer(to, amt), "pay");
    }
}

contract Borrower {
    Token public immutable token;
    ArbDesk public immutable desk;
    address public immutable pool;
    uint256 public immutable arbAmount;
    bytes32 public constant CALLBACK = keccak256("ERC3156FlashBorrower.onFlashLoan");

    constructor(Token t, ArbDesk d, address pool_, uint256 arb) {
        token = t;
        desk = d;
        pool = pool_;
        arbAmount = arb;
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        require(msg.sender == pool, "pool");
        desk.pay(address(this), arbAmount);
        require(token.transfer(msg.sender, amount + fee), "repay");
        return CALLBACK;
    }
}

/// @dev Buggy lender. prevBalance is taken before the principal leaves.
contract FlashLoans {
    Token public immutable token;
    address public immutable treasury;
    uint256 public constant FEE_BPS = 10; // 0.1%

    constructor(Token t, address treasury_) {
        token = t;
        treasury = treasury_;
    }

    function flashFee(address, uint256 amount) public pure returns (uint256) {
        return amount * FEE_BPS / 10_000;
    }

    function flashLoan(address receiver, uint256 amount, bytes calldata data) external returns (bool) {
        uint256 prevBalance = token.balanceOf(address(this));
        uint256 fee = flashFee(address(token), amount);
        require(token.transfer(receiver, amount), "send");
        require(
            Borrower(receiver).onFlashLoan(msg.sender, address(token), amount, fee, data)
                == Borrower(receiver).CALLBACK(),
            "callback"
        );
        uint256 returnedAmount = token.balanceOf(address(this)) - prevBalance;
        // @> VULN: returnedAmount is only the fee, so amount + fee never fits
        if (returnedAmount < amount + fee) {
            revert("ErrorInsufficientFlashLoanReturn");
        }
        if (fee > 0) {
            require(token.transfer(treasury, fee), "fee");
        }
        return true;
    }
}

/// @dev Audited fix: sample the balance after the principal transfer.
contract FixedFlashLoans {
    Token public immutable token;
    address public immutable treasury;
    uint256 public constant FEE_BPS = 10;

    constructor(Token t, address treasury_) {
        token = t;
        treasury = treasury_;
    }

    function flashFee(address, uint256 amount) public pure returns (uint256) {
        return amount * FEE_BPS / 10_000;
    }

    function flashLoan(address receiver, uint256 amount, bytes calldata data) external returns (bool) {
        uint256 fee = flashFee(address(token), amount);
        require(token.transfer(receiver, amount), "send");
        uint256 prevBalance = token.balanceOf(address(this));
        require(
            Borrower(receiver).onFlashLoan(msg.sender, address(token), amount, fee, data)
                == Borrower(receiver).CALLBACK(),
            "callback"
        );
        uint256 returnedAmount = token.balanceOf(address(this)) - prevBalance;
        if (returnedAmount < amount + fee) {
            revert("ErrorInsufficientFlashLoanReturn");
        }
        if (fee > 0) {
            require(token.transfer(treasury, fee), "fee");
        }
        return true;
    }
}

contract Exploit {
    Token public token; // CREATE 1
    ArbDesk public desk; // CREATE 2
    FlashLoans public pool; // CREATE 3
    Borrower public borrower; // CREATE 4
    address public treasury = 0x2222222222222222222222222222222222222222;

    bool public loanReverted;
    uint256 public borrowerEnd;
    uint256 public deskEnd;
    uint256 public treasuryEnd;
    uint256 public missedNet;

    uint256 public constant POOL = 1_000_000 ether;
    uint256 public constant AMOUNT = 100_000 ether;
    uint256 public constant ARB = 1_000 ether;
    uint256 public constant FEE = 100 ether;

    constructor() {
        token = new Token();
        desk = new ArbDesk(token);
        pool = new FlashLoans(token, treasury);
        borrower = new Borrower(token, desk, address(pool), ARB);
    }

    function run() external {
        token.mint(address(pool), POOL);
        token.mint(address(desk), ARB);
        token.mint(address(borrower), FEE);
        uint256 startBal = token.balanceOf(address(borrower));
        (bool ok,) = address(pool).call(
            abi.encodeWithSelector(pool.flashLoan.selector, address(borrower), AMOUNT, bytes(""))
        );
        loanReverted = !ok;
        borrowerEnd = token.balanceOf(address(borrower));
        deskEnd = token.balanceOf(address(desk));
        treasuryEnd = token.balanceOf(treasury);
        missedNet = ARB - FEE;
        require(loanReverted, "loan should revert");
        require(borrowerEnd == startBal, "prefund unchanged");
        require(deskEnd == ARB, "arb unpaid");
        require(treasuryEnd == 0, "no fee");
        require(missedNet == 900 ether, "missed net");
    }
}

contract ControlExploit {
    Token public token;
    ArbDesk public desk;
    FixedFlashLoans public pool;
    Borrower public borrower;
    address public treasury = 0x2222222222222222222222222222222222222222;

    uint256 public borrowerEnd;
    uint256 public deskEnd;
    uint256 public treasuryEnd;
    uint256 public net;

    uint256 public constant POOL = 1_000_000 ether;
    uint256 public constant AMOUNT = 100_000 ether;
    uint256 public constant ARB = 1_000 ether;
    uint256 public constant FEE = 100 ether;

    constructor() {
        token = new Token();
        desk = new ArbDesk(token);
        pool = new FixedFlashLoans(token, treasury);
        borrower = new Borrower(token, desk, address(pool), ARB);
    }

    function run() external {
        token.mint(address(pool), POOL);
        token.mint(address(desk), ARB);
        token.mint(address(borrower), FEE);
        pool.flashLoan(address(borrower), AMOUNT, bytes(""));
        borrowerEnd = token.balanceOf(address(borrower));
        deskEnd = token.balanceOf(address(desk));
        treasuryEnd = token.balanceOf(treasury);
        net = borrowerEnd - FEE;
        require(borrowerEnd == ARB, "kept arb");
        require(deskEnd == 0, "desk paid");
        require(treasuryEnd == FEE, "fee collected");
        require(net == 900 ether, "net 900");
        require(token.balanceOf(address(pool)) == POOL, "principal back");
    }
}
