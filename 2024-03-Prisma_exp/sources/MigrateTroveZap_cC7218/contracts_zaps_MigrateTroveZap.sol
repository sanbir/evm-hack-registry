// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;
import "contracts/utils/Address.sol";
import { Ownable } from "contracts/access/Ownable.sol";
import "contracts/token/ERC20/IERC20.sol";
import "contracts/token/ERC20/utils/SafeERC20.sol";
import "contracts/interfaces/ITroveManager.sol";
import "contracts/interfaces/IDebtToken.sol";
import "contracts/interfaces/IBorrowerOperations.sol";

/**
    @title Prisma Migrate Trove Zap
    @notice Zap to automate migrating to a different version of a Trove Manager
            for the same collateral.
 */
contract MigrateTroveZap is Ownable {
    using SafeERC20 for IERC20;
    using Address for address;
    bytes32 private constant _RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 public immutable DEBT_GAS_COMPENSATION;

    IBorrowerOperations public immutable borrowerOps;
    IDebtToken public immutable debtToken;
    // State  ---------------------------------------------------------------------------------------------------------
    mapping(address collateral => bool approved) public approvedCollaterals;
    // Events ---------------------------------------------------------------------------------------------------------

    event TroveMigrated(address account, address troveManagerFrom, address troveManagerTo, uint256 coll, uint256 debt);
    event NewTokenRegistered(address token);
    event EmergencyEtherRecovered(uint256 amount);
    event EmergencyERC20Recovered(address tokenAddress, uint256 tokenAmount);

    constructor(IBorrowerOperations _borrowerOps, IDebtToken _debtToken) {
        borrowerOps = _borrowerOps;
        debtToken = _debtToken;
        IDebtToken(debtToken).approve(address(_borrowerOps), type(uint256).max);
        IDebtToken(debtToken).approve(address(_debtToken), type(uint256).max);
        DEBT_GAS_COMPENSATION = _debtToken.DEBT_GAS_COMPENSATION();
    }

    // Admin routines ---------------------------------------------------------------------------------------------------

    /// @notice For emergencies if something gets stuck
    function recoverEther(uint256 amount) external onlyOwner {
        (bool success, ) = owner().call{ value: amount }("");
        require(success, "Invalid transfer");

        emit EmergencyEtherRecovered(amount);
    }

    /// @notice For emergencies if someone accidentally sent some ERC20 tokens here
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);

        emit EmergencyERC20Recovered(tokenAddress, tokenAmount);
    }

    // Public functions -------------------------------------------------------------------------------------------------

    /// @notice Flashloan callback function
    function onFlashLoan(
        address,
        address,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        require(msg.sender == address(debtToken), "!DebtToken");
        (
            address account,
            address troveManagerFrom,
            address troveManagerTo,
            uint256 maxFeePercentage,
            uint256 coll,
            address upperHint,
            address lowerHint
        ) = abi.decode(data, (address, address, address, uint256, uint256, address, address));
        uint256 toMint = amount + fee;
        borrowerOps.closeTrove(troveManagerFrom, account);
        borrowerOps.openTrove(troveManagerTo, account, maxFeePercentage, coll, toMint, upperHint, lowerHint);
        return _RETURN_VALUE;
    }

    /// @notice Migrates a trove to another TroveManager for the same collateral
    function migrateTrove(
        ITroveManager troveManagerFrom,
        ITroveManager troveManagerTo,
        uint256 maxFeePercentage,
        address upperHint,
        address lowerHint
    ) external {
        address collateral = troveManagerFrom.collateralToken();
        require(address(troveManagerTo) != address(troveManagerFrom), "Cannot migrate to same TM");
        require(collateral == troveManagerTo.collateralToken(), "Migration not supported");
        (uint256 coll, uint256 debt) = troveManagerFrom.getTroveCollAndDebt(msg.sender);
        require(debt > 0, "Trove not active");
        // One SLOAD to allow set and forget
        if (!approvedCollaterals[collateral]) {
            IERC20(collateral).approve(address(borrowerOps), type(uint256).max);
            approvedCollaterals[collateral] = true;
        }
        debtToken.flashLoan(
            address(this),
            address(debtToken),
            debt - DEBT_GAS_COMPENSATION,
            abi.encode(
                msg.sender,
                address(troveManagerFrom),
                address(troveManagerTo),
                maxFeePercentage,
                coll,
                upperHint,
                lowerHint
            )
        );
        emit TroveMigrated(msg.sender, address(troveManagerFrom), address(troveManagerTo), coll, debt);
    }

    receive() external payable {}
}
