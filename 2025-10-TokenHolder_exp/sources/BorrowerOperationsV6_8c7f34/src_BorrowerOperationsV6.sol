// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.29;

import "./TokenHolder.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

struct LoanRecord {
    uint256 id;
    address tokenHolder;
}

/// @custom:oz-upgrades-from src/BorrowerOperationsV5.sol:BorrowerOperationsV5
contract BorrowerOperationsV6 is ReentrancyGuardUpgradeable {
    
    uint256 constant MAX_INT = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    address constant FEE_ADDRESS = 0x8432CD30C4d72Ee793399E274C482223DCA2bF9e;
    IERC20 weth;
    uint256 public openingFee; // Opening fee as a percentage (e.g., 100 = 1%)
    uint256 public profitFee; // Profit fee as a percentage (e.g., 1000 = 10%)
    address public admin;
    mapping(address => LoanRecord[]) public loanRecords;
    
    // DEX whitelist management
    mapping(address => bool) public whitelistedDexes;
    mapping(address => bool) public whitelistedTokens;
    uint256 public maxApprovalAmount; // Maximum amount that can be approved to any DEX
    event Buy(address indexed buyer, address indexed tokenHolder, address indexed tokenCollateral, uint256 loanId, uint256 openingPositionSize, uint256 collateralAmount, uint256 initialMargin);
    event Sell(address indexed buyer, address indexed tokenHolder, address indexed tokenCollateral, uint256 loanId, uint256 closingPositionSize, uint256 profit);
    event Liquidation(address indexed borrower, address indexed tokenHolder, address indexed tokenCollateral, uint256 loanId, uint256 closingPositionSize, uint256 liquidatorRepaidAmount);
    
    // DEX and token management events
    event DexAdded(address indexed dex);
    event DexRemoved(address indexed dex);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event MaxApprovalAmountUpdated(uint256 oldAmount, uint256 newAmount);

    function initialize(IERC20 _weth) public initializer {
        weth = _weth;
        admin = msg.sender;
        openingFee = 50; // Default 1% opening fee
        profitFee = 800; // Default 10% profit fee
        maxApprovalAmount = 1000 ether; // Default max approval amount
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    function setAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    function setOpeningFee(uint256 _openingFee) external onlyAdmin {
        openingFee = _openingFee;
    }

    function setProfitFee(uint256 _profitFee) external onlyAdmin {
        profitFee = _profitFee;
    }

    // DEX whitelist management functions
    function addWhitelistedDex(address dex) external onlyAdmin {
        require(dex != address(0), "Invalid DEX address");
        whitelistedDexes[dex] = true;
        emit DexAdded(dex);
    }

    function removeWhitelistedDex(address dex) external onlyAdmin {
        whitelistedDexes[dex] = false;
        emit DexRemoved(dex);
    }

    function isWhitelistedDex(address dex) external view returns (bool) {
        return whitelistedDexes[dex];
    }

    // Token whitelist management functions
    function addWhitelistedToken(address token) external onlyAdmin {
        require(token != address(0), "Invalid token address");
        whitelistedTokens[token] = true;
        emit TokenAdded(token);
    }

    function removeWhitelistedToken(address token) external onlyAdmin {
        whitelistedTokens[token] = false;
        emit TokenRemoved(token);
    }

    function isWhitelistedToken(address token) external view returns (bool) {
        return whitelistedTokens[token];
    }

    // Max approval amount management
    function setMaxApprovalAmount(uint256 _maxApprovalAmount) external onlyAdmin {
        require(_maxApprovalAmount > 0, "Max approval amount must be greater than 0");
        uint256 oldAmount = maxApprovalAmount;
        maxApprovalAmount = _maxApprovalAmount;
        emit MaxApprovalAmountUpdated(oldAmount, _maxApprovalAmount);
    }

    function buy(bytes calldata buyingCode, IERC20 tokenCollateral, uint256 borrowAmount, TokenHolder tokenHolder, address inchRouter, address integratorFeeAddress, address whitelistedDex) external payable nonReentrant {
        // Security checks
        // require(whitelistedDexes[whitelistedDex], "DEX not whitelisted");
        // require(whitelistedTokens[address(tokenCollateral)], "Token not whitelisted");
        // require(whitelistedDexes[inchRouter], "Router not whitelisted");
        
        // Calculate total amount needed and ensure it doesn't exceed max approval
        uint256 totalAmount = borrowAmount + msg.value;
        //require(totalAmount <= maxApprovalAmount, "Amount exceeds max approval limit");
        
        // Approve only the exact amount needed instead of MAX_INT
        weth.approve(whitelistedDex, totalAmount);
        uint256 buyerContribution = msg.value;
        (bool success,) = payable(address(weth)).call{value: buyerContribution}("");
        require(success, "WETH failed");
        tokenHolder.privilegedLoan(weth, borrowAmount);
        
        
        (success,) = inchRouter.call(buyingCode);
        require(success, "Buy token failed");
        // at this state collateral is in this contract
        uint256 balanceCollateral = tokenCollateral.balanceOf(address(this));
        uint256 totalFee = balanceCollateral*openingFee/10000;
        // Transfer the fee
        if (integratorFeeAddress == address(0)) {
            // If integrator fee address is empty, transfer all fee to the fee address
            require(tokenCollateral.transfer(FEE_ADDRESS, totalFee), "Fee transfer failed");
        } else {
            // Split the fee in half between fee address and integratorFeeAddress
            uint256 halfFee = totalFee / 2;
            require(tokenCollateral.transfer(FEE_ADDRESS, halfFee), "Fee transfer to FEE_ADDRESS failed");
            require(tokenCollateral.transfer(integratorFeeAddress, totalFee - halfFee), "Fee transfer to integratorFeeAddress failed");
        }
        uint256 loanId = tokenHolder.loanConfirmation(borrowAmount, balanceCollateral - totalFee, address(tokenCollateral), msg.sender, buyerContribution);
        require(tokenCollateral.transfer(address(tokenHolder), balanceCollateral - totalFee), "Collateral transfer failed");
        loanRecords[msg.sender].push(LoanRecord(loanId, address(tokenHolder)));
        // Emit the Buy event
        emit Buy(msg.sender, address(tokenCollateral), address(tokenHolder), loanId, borrowAmount + buyerContribution, balanceCollateral - totalFee, buyerContribution);
    }

    function sell(uint256 loanId, bytes calldata sellingCode, TokenHolder tokenHolder, address inchRouter, address integratorFeeAddress, address whitelistedDex) external payable nonReentrant {
        // Security checks
        // require(whitelistedDexes[whitelistedDex], "DEX not whitelisted");
        // require(whitelistedDexes[inchRouter], "Router not whitelisted");
        
        // this is memory, won't change even loan is repaid
        (,uint256 borrowAmount, Collateral memory collateral, uint256 collateralAmount,,address borrower, uint256 userPaid) = tokenHolder.loans(loanId);
        
        // // Check if collateral token is whitelisted
        // require(whitelistedTokens[collateral.collateralAddress], "Collateral token not whitelisted");
        
        // // Ensure collateral amount doesn't exceed max approval
        // require(collateralAmount <= maxApprovalAmount, "Collateral amount exceeds max approval limit");
        
        tokenHolder.privilegedLoan(IERC20(collateral.collateralAddress), collateralAmount);
        IERC20(collateral.collateralAddress).approve(whitelistedDex, collateralAmount);
        (bool success,) = inchRouter.call(sellingCode);
        require(success, "Sell token failed");
        uint256 closingPositionSize = weth.balanceOf(address(this));
        // add more WETH if needed
        (bool success2,) = payable(address(weth)).call{value: msg.value}("");
        require(success2, "WETH failed");
        weth.approve(address(tokenHolder), MAX_INT);
        tokenHolder.repayLoan(loanId, false);
        // transfer profits
        uint256 balance = weth.balanceOf(address(this));
        uint256 profit = balance > userPaid ? balance - userPaid : 0;
        // Calculate the fee
        uint256 totalFee = profit*profitFee/10000 + (borrowAmount+userPaid)*openingFee/10000;
        // Transfer the fee
        if (integratorFeeAddress == address(0)) {
            // If integrator fee address is empty, transfer all fee to the fee address
            require(weth.transfer(FEE_ADDRESS, totalFee), "Fee transfer failed");
        } else {
            // Split the fee in half between fee address and integratorFeeAddress
            require(weth.transfer(FEE_ADDRESS, totalFee / 2), "Fee transfer to FEE_ADDRESS failed");
            require(weth.transfer(integratorFeeAddress, totalFee - totalFee / 2), "Fee transfer to integratorFeeAddress failed");
        }
        weth.transfer(borrower, weth.balanceOf(address(this)));
        emit Sell(borrower, address(collateral.collateralAddress), address(tokenHolder), loanId, closingPositionSize, profit);
    }

    function liquidate(uint256 loanId, TokenHolder tokenHolder, uint256 closingPositionSize) external onlyAdmin nonReentrant {
        (,uint256 amount, Collateral memory collateral, uint256 collateralAmount,uint256 timestamp,address borrower, ) = tokenHolder.loans(loanId);
        
        // Check if collateral token is whitelisted
        // require(whitelistedTokens[collateral.collateralAddress], "Collateral token not whitelisted");
        
        tokenHolder.privilegedLoan(IERC20(collateral.collateralAddress), collateralAmount);

        // uint256 loanDuration = block.timestamp - timestamp; // Calculate the duration of the loan in seconds
        // uint256 daysElapsed = (loanDuration + 1 days - 1) / 1 days; // Round up to the nearest day
        // uint256 interestAmount = (amount *
        //     collateral.interestRate *
        //     daysElapsed) / (365 * 100); // Calculate interest based on APR and days elapsed

        // uint256 totalAmountDue = amount + interestAmount;

        // weth.transferFrom(msg.sender, address(this), totalAmountDue);
        // weth.approve(address(tokenHolder), MAX_INT);
        tokenHolder.repayLoan(loanId, true);
        IERC20(collateral.collateralAddress).transfer(msg.sender, collateralAmount);
        emit Liquidation(borrower, address(collateral.collateralAddress), address(tokenHolder), loanId, closingPositionSize, amount);
    }

}