// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title MultiSign contract
 * @author Autonomint
 * @notice Contract that is used for MultiSign feature
 * - Owners can:
 *   # Pause specific function in Borrow or CDS
 *   # Pause entire Borrowing or CDS contract
 *   # Approve setter functions to set addresses, ltv etc.
 * @dev All admin functions are callable by the admin address only
 * @dev Checks whether the function or contract is paused or not.
 */

contract MultiSign is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    address[] private owners; // Owners array
    uint8 private maxOwners; // Maximum number of owners approval required
    uint8 private noOfOwners; // Total number of owners
    mapping(address => bool) public isOwner; // To check the address is owner
    uint64 private requiredApprovals; // Required number of approvals to execute the function
    enum SetterFunctions {
        SetLTV, // To set LTV of the protocol
        SetAPR, // To set APR of the protocol
        SetWithdrawTimeLimitCDS, // To set withdraw time limit in CDS
        SetAdminBorrow, // To set ADMIN in borrow
        SetAdminCDS, // TO set ADMIN in CDS
        SetTreasuryBorrow, // To set treasury contract address in borrow
        SetTreasuryCDS, // To set treasury contract address in CDS
        SetBondRatio, // To set ABOND-USDa ratio in Borrow
        SetUSDaLimit, // To set minimum percentage of USDa to deposit in CDS
        SetUsdtLimit // To set minimum percentage of USDT to deposit in CDS
    }
    enum Functions {
        BorrowingDeposit, // Deposit function in borrow
        BorrowingWithdraw, // Withdraw function in borrow
        Liquidation, // Liquidation function
        SetAPR, // Set APR function in borrow
        CDSDeposit, // Deposit function in CDS
        CDSWithdraw, // Withdraw function in CDS
        RedeemUSDT // Redeem USDT function in CDS
    }

    mapping(SetterFunctions => mapping(address owner => bool approved)) public approvedToUpdate; // Check which owners were approved

    mapping(Functions => mapping(address owner => bool paused)) public pauseApproved; // Store what functions are approved for pause by owners
    mapping(Functions => mapping(address owner => bool unpaused)) public unpauseApproved; // Store what functions are approved for unpause by owners

    mapping(Functions => bool paused) public functionState; // Returns true if function is in pause state

    /**
     * @dev Initialize function to initialize the contract
     * @param _owners owners address in array
     * @param _requiredApprovals number of owners approvals required
     */
    function initialize(
        address[] memory _owners,
        uint64 _requiredApprovals
    ) public initializer {
        // initialize the owner
        __Ownable_init(msg.sender);
        //Initialize the proxy
        __UUPSUpgradeable_init();
        uint8 _noOfOwners = uint8(_owners.length);
        // Check whether the number of owners is not a zero
        require(_noOfOwners > 0, "Owners required");
        maxOwners = 10;
        // Check whether the owners reached maximum limit
        require( _noOfOwners <= maxOwners,"Number of owners should be below maximum owners limit");
        // Check whether the required approvals are lessthan or equal to the number of owners
        require(_requiredApprovals > 0 && _requiredApprovals <= _noOfOwners,"Invalid number of required approvals");

        for (uint64 i; i < _noOfOwners; i++) {
            address _owner = _owners[i];
            // Check the owner address is non zero
            require(_owner != address(0), "Invalid owner");
            // Check, the same owner address is not repeated
            require(!isOwner[_owner], "Duplicate owner");

            isOwner[_owner] = true;
            owners.push(_owner);
        }

        requiredApprovals = _requiredApprovals;
        noOfOwners = _noOfOwners;
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    /**
     * @dev modifier to check whether the caller is owner or not
     */
    modifier onlyOwners() {
        require(isOwner[msg.sender], "Not an owner");
        _;
    }

    /**
     * @dev Function to approve pause functions
     * @param functions Which functions needs to pause
     */
    function approvePause(uint8[] memory functions) external onlyOwners {
        uint8 noOfFunctions = uint8(functions.length);
        // Check, the given functions are not empty
        require(noOfFunctions > 0, "Empty array");
        // Loop through the functions to approve pause functions
        for (uint8 i = 0; i < noOfFunctions; i++) {
            // Check, the caller(owner) has already approved to pause given function
            require(!pauseApproved[Functions(functions[i])][msg.sender],"Already approved");
            // Change the mapping to true
            pauseApproved[Functions(functions[i])][msg.sender] = true;
        }
    }

    /**
     * @dev Function to approve setter functions
     * @param functions Which functions needs to set
     */
    function approveSetterFunction(
        uint8[] memory functions
    ) external onlyOwners {
        uint8 noOfFunctions = uint8(functions.length);
        // Check, the given functions are not empty
        require(noOfFunctions > 0, "Empty array");
        // Loop through the functions to approve setter functions
        for (uint8 i = 0; i < noOfFunctions; i++) {
            // Check, the caller(owner) has already approved to set given function
            require(!approvedToUpdate[SetterFunctions(functions[i])][msg.sender],"Already approved");
            // Change the mapping to true
            approvedToUpdate[SetterFunctions(functions[i])][msg.sender] = true;
        }
    }

    /**
     * @dev Function to approve unpause functions
     * @param functions Which functions needs to pause
     */
    function approveUnPause(uint8[] memory functions) external onlyOwners {
        uint8 noOfFunctions = uint8(functions.length);
        // Check, the given functions are not empty
        require(noOfFunctions > 0, "Empty array");
        // Loop through the functions to approve unpause functions
        for (uint8 i = 0; i < noOfFunctions; i++) {
            // Check, the caller(owner) has already approved to unpause given function
            require(!unpauseApproved[Functions(functions[i])][msg.sender],"Already approved");
            // Change the mapping to true
            unpauseApproved[Functions(functions[i])][msg.sender] = true;
        }
    }

    /**
     * @dev Function to approve ,pause borrowing contracts
     */
    function approveBorrowingPause() external onlyOwners {
        // Check, the caller(owner) has already approved to pause borrowing contract functions
        require(!pauseApproved[Functions.BorrowingDeposit][msg.sender],"BorrowingDeposit Already approved");
        require(!pauseApproved[Functions.BorrowingWithdraw][msg.sender],"BorrowingWithdraw Already approved");
        require(!pauseApproved[Functions.Liquidation][msg.sender],"Liquidation Already approved");
        require(!pauseApproved[Functions.SetAPR][msg.sender],"SetAPR Already approved");

        // Change the mapping to true
        pauseApproved[Functions.BorrowingDeposit][msg.sender] = true;
        pauseApproved[Functions.BorrowingWithdraw][msg.sender] = true;
        pauseApproved[Functions.Liquidation][msg.sender] = true;
        pauseApproved[Functions.SetAPR][msg.sender] = true;
    }

    /**
     * @dev Function to approve ,pause CDS contracts
     */
    function approveCDSPause() external onlyOwners {
        // Check, the caller(owner) has already approved to pause cds contract function
        require(!pauseApproved[Functions.CDSDeposit][msg.sender],"CDSDeposit Already approved");
        require(!pauseApproved[Functions.CDSWithdraw][msg.sender],"CDSWithdraw Already approved");
        require(!pauseApproved[Functions.RedeemUSDT][msg.sender],"RedeemUSDT Already approved");

        // Change the mapping to true
        pauseApproved[Functions.CDSDeposit][msg.sender] = true;
        pauseApproved[Functions.CDSWithdraw][msg.sender] = true;
        pauseApproved[Functions.RedeemUSDT][msg.sender] = true;
    }

    /**
     * @dev Function to approve ,unpause borrowing contracts
     */
    function approveBorrowingUnPause() external onlyOwners {
        // Check, the caller(owner) has already approved to unpause borrowing contract function
        require(!unpauseApproved[Functions.BorrowingDeposit][msg.sender],"BorrowingDeposit Already approved");
        require(!unpauseApproved[Functions.BorrowingWithdraw][msg.sender],"BorrowingWithdraw Already approved");
        require(!unpauseApproved[Functions.Liquidation][msg.sender],"Liquidation Already approved");
        require(!unpauseApproved[Functions.SetAPR][msg.sender],"SetAPR Already approved");

        // Change the mapping to true
        unpauseApproved[Functions.BorrowingDeposit][msg.sender] = true;
        unpauseApproved[Functions.BorrowingWithdraw][msg.sender] = true;
        unpauseApproved[Functions.Liquidation][msg.sender] = true;
        unpauseApproved[Functions.SetAPR][msg.sender] = true;
    }

    /**
     * @dev Function to approve ,unpause cds contracts
     */
    function approveCDSUnPause() external onlyOwners {
        // Check, the caller(owner) has already approved to unpause cds contract function
        require(!unpauseApproved[Functions.CDSDeposit][msg.sender],"CDSDeposit Already approved");
        require(!unpauseApproved[Functions.CDSWithdraw][msg.sender],"CDSWithdraw Already approved");
        require(!unpauseApproved[Functions.RedeemUSDT][msg.sender],"RedeemUSDT Already approved");

        // Change the mapping to true
        unpauseApproved[Functions.CDSDeposit][msg.sender] = true;
        unpauseApproved[Functions.CDSWithdraw][msg.sender] = true;
        unpauseApproved[Functions.RedeemUSDT][msg.sender] = true;
    }

    /**
     * @dev Gets the pause approval count for the specfic function
     */
    function getApprovalPauseCount(
        Functions _function
    ) private view returns (uint64) {
        uint64 count;
        // Loop through the approved functions with owners mapping and get the approval count
        for (uint64 i; i < noOfOwners; i++) {
            // Check the owner has approved function to pause
            if (pauseApproved[_function][owners[i]]) {
                count += 1;
            }
        }
        return count;
    }

    /**
     * @dev Gets the unpause approval count for the specfic function
     */
    function getApprovalUnPauseCount(
        Functions _function
    ) private view returns (uint64) {
        uint64 count;
        // Loop through the approved functions with owners mapping and get the approval count
        for (uint64 i; i < noOfOwners; i++) {
            // Check the owner has approved function to unpause
            if (unpauseApproved[_function][owners[i]]) {
                count += 1;
            }
        }
        return count;
    }

    /**
     * @dev Gets the setter approval count for the specfic function
     */
    function getSetterFunctionApproval(
        SetterFunctions _function
    ) private view returns (uint64) {
        uint64 count;
        // Loop through the approved functions with owners mapping and get the approval count
        for (uint64 i; i < noOfOwners; i++) {
            // Check the owner has approved function to set
            if (approvedToUpdate[_function][owners[i]]) {
                count += 1;
            }
        }
        return count;
    }

    /**
     * @dev Pause the function, If reqired approvals from the owners met
     * @param _function Fucntion to execute pause
     */
    function executePause(Functions _function) private returns (bool) {
        // Get the number of approvals
        require(getApprovalPauseCount(_function) >= requiredApprovals,"Required approvals not met");
        // Loop through the approved functions with owners mapping and change to false
        for (uint64 i; i < noOfOwners; i++) {
            pauseApproved[_function][owners[i]] = false;
        }
        return true;
    }

    /**
     * @dev UnPause the function, If reqired approvals from the owners met
     * @param _function Fucntion to execute unpause
     */
    function executeUnPause(Functions _function) private returns (bool) {
        // Get the number of approvals
        require(getApprovalUnPauseCount(_function) >= requiredApprovals,"Required approvals not met");
        // Loop through the approved functions with owners mapping and change to false
        for (uint64 i; i < noOfOwners; i++) {
            unpauseApproved[_function][owners[i]] = false;
        }
        return true;
    }

    /**
     * @dev Set the function, If reqired approvals from the owners met
     * @param _function Fucntion to execute setter
     */
    function executeSetterFunction(
        SetterFunctions _function
    ) external returns (bool) {
        // Get the number of approvals
        require(getSetterFunctionApproval(_function) >= requiredApprovals,"Required approvals not met");
        // Loop through the approved functions with owners mapping and change to false
        for (uint64 i; i < noOfOwners; i++) {
            approvedToUpdate[_function][owners[i]] = false;
        }
        return true;
    }

    /**
     * @dev Pause the functions, If reqired approvals from the owners met
     * @param functions Fucntions to execute pause
     */
    function pauseFunction(uint8[] memory functions) external onlyOwners {
        uint8 noOfFunctions = uint8(functions.length);
        // Check, the given functions are not empty
        require(noOfFunctions > 0, "Empty array");
        // Loop through the approved functions with owners mapping and change to true
        for (uint8 i = 0; i < noOfFunctions; i++) {
            // Execute the pause for given functions, check if returned true
            require(executePause(Functions(functions[i])));
            functionState[Functions(functions[i])] = true;
        }
    }

    /**
     * @dev UnPause the functions, If reqired approvals from the owners met
     * @param functions Fucntions to execute unpause
     */
    function unpauseFunction(uint8[] memory functions) external onlyOwners {
        uint8 noOfFunctions = uint8(functions.length);
        // Check, the given functions are not empty
        require(noOfFunctions > 0, "Empty array");
        // Loop through the approved functions with owners mapping and change to false
        for (uint8 i = 0; i < noOfFunctions; i++) {
            // Execute the unpause for given functions, check if returned true
            require(executeUnPause(Functions(functions[i])));
            functionState[Functions(functions[i])] = false;
        }
    }

    /**
     * @dev Pause the borrowing contract functions, If reqired approvals from the owners met
     */
    function pauseBorrowing() external onlyOwners {
        // Execute the pause for all borrowing functions, check if returned true
        require(
            executePause(Functions(0)) &&
            executePause(Functions(1)) &&
            executePause(Functions(2)) &&
            executePause(Functions(3))
        );
        // Change the mapping to true
        functionState[Functions.BorrowingDeposit] = true;
        functionState[Functions.BorrowingWithdraw] = true;
        functionState[Functions.Liquidation] = true;
        functionState[Functions.SetAPR] = true;
    }

    /**
     * @dev Pause the cds contract functions, If reqired approvals from the owners met
     */
    function pauseCDS() external onlyOwners {
        // Execute the pause for all cds functions, check if returned true
        require(
            executePause(Functions(4)) &&
            executePause(Functions(5)) &&
            executePause(Functions(6))
        );
        // Change the mapping to true
        functionState[Functions.CDSDeposit] = true;
        functionState[Functions.CDSWithdraw] = true;
        functionState[Functions.RedeemUSDT] = true;
    }

    /**
     * @dev UnPause the borrowing contract functions, If reqired approvals from the owners met
     */
    function unpauseBorrowing() external onlyOwners {
        // Execute the unpause for all borrowing functions, check if returned true
        require(
            executeUnPause(Functions(0)) &&
            executeUnPause(Functions(1)) &&
            executeUnPause(Functions(2)) &&
            executeUnPause(Functions(3))
        );
        // Change the mapping to false
        functionState[Functions.BorrowingDeposit] = false;
        functionState[Functions.BorrowingWithdraw] = false;
        functionState[Functions.Liquidation] = false;
        functionState[Functions.SetAPR] = false;
    }

    /**
     * @dev UnPause the cds contract functions, If reqired approvals from the owners met
     */
    function unpauseCDS() external onlyOwners {
        // Execute the unpause for all cds functions, check if returned true
        require(
            executeUnPause(Functions(4)) &&
            executeUnPause(Functions(5)) &&
            executeUnPause(Functions(6))
        );
        // Change the mapping to false
        functionState[Functions.CDSDeposit] = false;
        functionState[Functions.CDSWithdraw] = false;
        functionState[Functions.RedeemUSDT] = false;
    }
}
