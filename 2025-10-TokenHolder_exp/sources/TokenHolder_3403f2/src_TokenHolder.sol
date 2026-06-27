pragma solidity 0.8.29;
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
// Import the ERC-20 interface

struct Loan {
    uint256 id;
    uint256 amount;
    Collateral collateral;
    uint256 collateralAmount;
    uint256 timestamp;
    address borrower;
    uint256 userPaid;
}

struct Collateral {
    address collateralAddress;
    uint256 maxLendPerToken;
    uint256 interestRate;
    bool active;
    uint256 minAmount;
    uint256 maxExposure;      // Maximum total amount that can be lent against this collateral
    uint256 currentExposure;  // Current total amount borrowed against this collateral
}

contract TokenHolder is AccessControlUpgradeable {
    IERC20 public tokenHolded; // Address of the ERC-20 token contract

    mapping(address => Collateral) public collateralMapping;
    mapping(uint256 => Loan) public loans;
    
    // Track all active loan IDs for easier client-side access
    uint256[] public activeLoanIds;
    // Map loan ID to its index in the activeLoanIds array for O(1) removal
    mapping(uint256 => uint256) private loanIdToArrayIndex;
    
    uint256 public nextLoanId;

    bytes32 public constant BORROWER_ROUTER_ROLE =
        keccak256("BORROWER_ROUTER_ROLE");

    event LoanCreated(
        uint256 loanId,
        uint256 amount,
        uint256 timestamp,
        bool repaid
    );
    event LoanRepaid(uint256 loanId);
    event PrivilegedLoan(address borrower, uint256 amount);
    event PrivilegedLoanRepaid(address borrower, uint256 amount);
    event InterestRateSet(uint256 newInterestRate);
    event ExposureUpdated(address collateralAddress, uint256 currentExposure);
    event MaxExposureUpdated(address collateralAddress, uint256 oldMaxExposure, uint256 newMaxExposure);

    function initialize(address _tokenAddress) public initializer {
        tokenHolded = IERC20(_tokenAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    modifier onlyBorrowerRouter() {
        require(
            hasRole(BORROWER_ROUTER_ROLE, msg.sender),
            "Only the borrower router can call this function"
        );
        _;
    }

    // Deposit tokens into the contract
    function deposit(uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Amount must be greater than 0");
        require(
            tokenHolded.transferFrom(msg.sender, address(this), amount),
            "Token transfer failed"
        );
    }

    // Withdraw tokens from the contract
    function withdraw(uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Amount must be greater than 0");
        require(tokenHolded.transfer(msg.sender, amount), "Token transfer failed");
    }

    // Get the contract's token balance
    function getBalance() public view returns (uint256) {
        return tokenHolded.balanceOf(address(this));
    }

    // Create a new loan with collateral
    function loanConfirmation(
        uint256 amount,
        uint256 collateralAmount,
        address collateralAddress,
        address borrower,
        uint256 userPaid
    ) public onlyBorrowerRouter returns (uint256) {
        require(amount > 0, "Amount must be greater than 0");
        require(
            tokenHolded.balanceOf(address(this)) >= amount,
            "Insufficient funds in the contract"
        );
        
        Collateral storage collateral = collateralMapping[collateralAddress];
        
        require(
            collateral.active,
            "Collateral not supported"
        );
        
        require(
            collateral.currentExposure + amount <= collateral.maxExposure,
            "Exposure limit exceeded for this collateral"
        );

        require(
            (collateralAmount *
                collateral.maxLendPerToken) /
                10 ** ERC20Upgradeable(collateralAddress).decimals() >=
                amount,
            "Borrowed too much"
        );
        
        // Update the current exposure for this collateral
        collateral.currentExposure += amount;
        emit ExposureUpdated(collateralAddress, collateral.currentExposure);

        uint256 loanId = nextLoanId;
        nextLoanId++;

        // Store the loan in mapping
        loans[loanId] = Loan(
            loanId,
            amount,
            collateral,
            collateralAmount,
            block.timestamp,
            borrower,
            userPaid
        );
        
        // Add to active loan IDs array and store its index
        loanIdToArrayIndex[loanId] = activeLoanIds.length;
        activeLoanIds.push(loanId);

        emit LoanCreated(loanId, amount, block.timestamp, false);

        return loanId;
    }

    // Repay a loan with interest based on time duration
    function repayLoan(uint256 loanId, bool withoutTransfer) public onlyBorrowerRouter {
        require(loanId < nextLoanId, "Invalid loan ID");
        Loan memory loanToRepay = loans[loanId];
        require(loanToRepay.amount > 0, "Loan does not exist or already repaid");
        
        address collateralAddress = loanToRepay.collateral.collateralAddress;
        
        uint256 loanDuration = block.timestamp - loanToRepay.timestamp; // Calculate the duration of the loan in seconds
        uint256 daysElapsed = (loanDuration + 1 days - 1) / 1 days; // Round up to the nearest day
        uint256 interestAmount = (loanToRepay.amount *
            loanToRepay.collateral.interestRate *
            daysElapsed) / (365 * 100); // Calculate interest based on APR and days elapsed

        uint256 totalAmountDue = loanToRepay.amount + interestAmount;

        if (!withoutTransfer) {
            require(
                tokenHolded.transferFrom(msg.sender, address(this), totalAmountDue),
                "Token transfer failed"
            );
        }
        

        // Update the current exposure for this collateral
        if (collateralMapping[collateralAddress].currentExposure >= loanToRepay.amount) {
            collateralMapping[collateralAddress].currentExposure -= loanToRepay.amount;
            emit ExposureUpdated(collateralAddress, collateralMapping[collateralAddress].currentExposure);
        } else {
            collateralMapping[collateralAddress].currentExposure = 0;
            emit ExposureUpdated(collateralAddress, 0);
        }

        // Remove from active loans array - swap and pop for gas efficiency
        uint256 indexToRemove = loanIdToArrayIndex[loanId];
        uint256 lastIndex = activeLoanIds.length - 1;
        
        if (indexToRemove != lastIndex) {
            uint256 lastLoanId = activeLoanIds[lastIndex];
            activeLoanIds[indexToRemove] = lastLoanId;
            loanIdToArrayIndex[lastLoanId] = indexToRemove;
        }
        
        activeLoanIds.pop();
        delete loanIdToArrayIndex[loanId];
        delete loans[loanId];

        emit LoanRepaid(loanId);
    }

    // Get the total number of active loans
    function getActiveLoanCount() public view returns (uint256) {
        return activeLoanIds.length;
    }
    
    // Get a batch of active loans (for efficient client-side fetching)
    function getActiveLoansBatch(uint256 startIndex, uint256 batchSize) 
        public 
        view 
        returns (Loan[] memory) 
    {
        uint256 endIndex = startIndex + batchSize;
        if (endIndex > activeLoanIds.length) {
            endIndex = activeLoanIds.length;
        }
        
        uint256 resultSize = endIndex - startIndex;
        Loan[] memory result = new Loan[](resultSize);
        
        for (uint256 i = 0; i < resultSize; i++) {
            uint256 loanId = activeLoanIds[startIndex + i];
            result[i] = loans[loanId];
        }
        
        return result;
    }
    
    // Get all loans associated with a specific borrower
    function getLoansByBorrower(address borrower) public view returns (Loan[] memory) {
        // First count how many loans belong to this borrower
        uint256 count = 0;
        for (uint256 i = 0; i < activeLoanIds.length; i++) {
            if (loans[activeLoanIds[i]].borrower == borrower) {
                count++;
            }
        }
        
        // Create array of appropriate size
        Loan[] memory borrowerLoans = new Loan[](count);
        
        // Fill the array
        uint256 index = 0;
        for (uint256 i = 0; i < activeLoanIds.length; i++) {
            uint256 loanId = activeLoanIds[i];
            if (loans[loanId].borrower == borrower) {
                borrowerLoans[index] = loans[loanId];
                index++;
            }
        }
        
        return borrowerLoans;
    }

    // Privileged loan without creating a record (requires borrowerRouter role)
    function privilegedLoan(
        IERC20 flashLoanToken,
        uint256 amount
    ) public onlyBorrowerRouter {
        require(amount > 0, "Amount must be greater than 0");
        require(
            flashLoanToken.balanceOf(address(this)) >= amount,
            "Insufficient funds in the contract"
        );

        require(
            flashLoanToken.transfer(msg.sender, amount),
            "Token transfer failed"
        );

        emit PrivilegedLoan(msg.sender, amount);
    }

    // Grant the borrowerRouter role to an address
    function grantBorrowerRouterRole(
        address account
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(BORROWER_ROUTER_ROLE, account);
    }

    // Revoke the borrowerRouter role from an address
    function revokeBorrowerRouterRole(
        address account
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(BORROWER_ROUTER_ROLE, account);
    }

    // Add collateral with leverage (only admin)
    function addCollateral(
        address collateralAddress,
        uint256 _interestRate,
        uint256 maxLendPerToken,
        uint256 minAmount,
        uint256 maxExposure
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxLendPerToken > 0, "Leverage amount must be greater than 0");
        require(collateralAddress != address(0), "Invalid collateral address");
        require(maxExposure > 0, "Max exposure must be greater than 0");

        collateralMapping[collateralAddress] = Collateral(
            collateralAddress,
            maxLendPerToken,
            _interestRate,
            true,
            minAmount,
            maxExposure,
            0  // Initial currentExposure is 0
        );
    }

    // Function to update maxExposure for a specific collateral
    function updateMaxExposure(
        address collateralAddress,
        uint256 newMaxExposure
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            collateralMapping[collateralAddress].active,
            "Collateral not found or not active"
        );
        require(newMaxExposure > 0, "Max exposure must be greater than 0");
        
        uint256 oldMaxExposure = collateralMapping[collateralAddress].maxExposure;
        collateralMapping[collateralAddress].maxExposure = newMaxExposure;
        
        emit MaxExposureUpdated(collateralAddress, oldMaxExposure, newMaxExposure);
    }

    // Function to get current exposure for a collateral
    function getCollateralExposure(address collateralAddress) public view returns (uint256) {
        return collateralMapping[collateralAddress].currentExposure;
    }

    // Function to get available exposure for a collateral
    function getAvailableExposure(address collateralAddress) public view returns (uint256) {
        Collateral memory collateral = collateralMapping[collateralAddress];
        if (!collateral.active) return 0;
        return collateral.maxExposure > collateral.currentExposure ? 
               collateral.maxExposure - collateral.currentExposure : 0;
    }

    // Event to emit when maxLendPerToken is updated
    event MaxLendPerTokenUpdated(
        address collateralAddress,
        uint256 oldValue,
        uint256 newValue
    );

    // Function to update maxLendPerToken for a specific collateral
    function updateMaxLendPerTokenBulk(
        address[] memory collateralAddresses,
        uint256[] memory newMaxLendPerTokens
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            collateralAddresses.length == newMaxLendPerTokens.length,
            "Array lengths must match"
        );

        for (uint256 i = 0; i < collateralAddresses.length; i++) {
            address collateralAddress = collateralAddresses[i];
            uint256 newMaxLendPerToken = newMaxLendPerTokens[i];

            require(
                collateralMapping[collateralAddress].active,
                "Collateral not found or not active"
            );

            uint256 oldMaxLendPerToken = collateralMapping[collateralAddress]
                .maxLendPerToken;
            collateralMapping[collateralAddress]
                .maxLendPerToken = newMaxLendPerToken;

            emit MaxLendPerTokenUpdated(
                collateralAddress,
                oldMaxLendPerToken,
                newMaxLendPerToken
            );
        }
    }

    // Remove collateral (only admin)
    function removeCollateral(
        address collateralAddress
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            collateralMapping[collateralAddress].active == true,
            "Collateral not found"
        );
        require(
            collateralMapping[collateralAddress].currentExposure == 0,
            "Cannot remove collateral with active loans"
        );

        delete collateralMapping[collateralAddress];
    }
}
