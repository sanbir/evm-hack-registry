// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./IVesting.sol";
import "./IVestingCalculator.sol";

interface IVestingManager is IERC721, IVesting {
    // Custom errors
    error InvalidBeneficiary();
    error InvalidToken();
    error InvalidAmount();
    error NotAuthorized();
    error VestingAlreadyCancelled();
    error NotCancellable();
    error NotSoftVesting();
    error OnlyCreatorCanCancel();
    error NonTransferableToken();
    error InvalidArray();
    error InvalidTime();
    error NFTAlreadyMinted();
    error InvalidCalculator();
    error InvalidSVGGenerator();
    error NotWhitelisted();
    error InvalidFeePercentage();
    error InvalidFeeCollector();
    error InvalidFlatFee();
    error OnlyOwner();
    error FeeTransferFailed();
    error NotTopable();
    error TokenDoesNotExist();

    // Events
    event VestingCreated(
        uint256 indexed vestingId,
        address indexed beneficiary,
        address token,
        IVestingCalculator.TimeAmount[] tranches,
        bool isSoft,
        bool isTopable,
        bool isTransferable
    );
    event TokensReleased(uint256 indexed vestingId, address indexed beneficiary, uint256 amount);
    event VestingCancelled(uint256 indexed vestingId);
    event AirdropVestingCreated(uint256[] vestingIds, address[] beneficiaries);
    event VestingTransferred(uint256 indexed vestingId, address indexed from, address indexed to);
    event VestingToppedUp(
        uint256 indexed vestingId,
        address indexed sender,
        uint256 amount,
        IVestingCalculator.TimeAmount[] tranches
    );
    event FeePercentageUpdated(uint256 newFeePercentage);
    event FlatFeeUpdated(uint256 newFlatFee);
    event FeeCollectorUpdated(address indexed oldFeeCollector, address indexed newFeeCollector);
    event SVGGeneratorUpdated(address indexed oldSVGGenerator, address indexed newSVGGenerator);
    event FeesCollected(address token, uint256 amount, uint256 flatFee);
    event TokenFeeExemptionUpdated(address token, bool isExempt);
    event CreatorFeeExemptionUpdated(address creator, bool isExempt);
    event FeeExemptionStatusUpdated(bool enabled);
    event BulkVestingCreated(uint256[] vestingIds, address indexed beneficiary);
    event BulkVestingCreatedForBeneficiaries(uint256[] vestingIds, address[] beneficiaries);

    struct VestingSchedule {
        address token;
        address creator;
        address beneficiary;
        uint256 totalAmount;
        uint256 released;
        bool isSoft;
        bool isNftized;
        bool cancelled;
        bool isTopable;
        IVesting.VestingType vestingType;
        IVestingCalculator.TimeAmount[] tranches;
    }

    // Function declarations
    function createVesting(
        address token,
        IVestingCalculator.TimeAmount[] calldata tranches,
        address beneficiary,
        bool isSoft,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) external payable returns (uint256);

    /// @notice Creates a daily soft vesting schedule
    /// @param token Address of the token to vest
    /// @param tranches Array of vesting tranches with time and amount
    /// @param beneficiary Address that will receive the vested tokens
    /// @return The ID of the created vesting schedule
    function createDailySoftVesting(
        address token,
        IVestingCalculator.TimeAmount[] calldata tranches,
        address beneficiary
    ) external payable returns (uint256);

    /// @notice Creates multiple vesting schedules in a single transaction
    /// @param token Address of the token to vest
    /// @param tranches Array of vesting tranches with time and amount
    /// @param beneficiaries Array of addresses that will receive the vested tokens
    /// @param isSoft Whether the vestings can be cancelled
    /// @param isNftized Whether the vesting NFTs can be minted
    /// @param isTransferable Whether the vesting NFTs can be transferred
    /// @param isTopable Whether the vestings can be topped up
    /// @return Array of created vesting IDs
    function createAirdropVesting(
        address token,
        IVestingCalculator.TimeAmount[] calldata tranches,
        address[] calldata beneficiaries,
        bool isSoft,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) external payable returns (uint256[] memory);

    /// @notice Creates multiple vestings for the same beneficiary in a single transaction
    /// @dev Supports multiple tokens and distinct tranche arrays per vesting
    /// @param tokens Array of token addresses for each vesting
    /// @param tranchesList Array of tranche arrays; each element is the tranche array for the corresponding vesting
    /// @param beneficiary The shared beneficiary for all created vestings
    /// @param isSoft Whether the vestings can be cancelled
    /// @param isNftized Whether the vesting NFTs can be minted
    /// @param isTransferable Whether the vesting NFTs can be transferred
    /// @param isTopable Whether the vestings can be topped up
    /// @return Array of created vesting IDs
    function createBulkVestingForBeneficiary(
        address[] calldata tokens,
        IVestingCalculator.TimeAmount[][] calldata tranchesList,
        address beneficiary,
        bool isSoft,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) external payable returns (uint256[] memory);

    /// @notice Creates multiple vestings for multiple beneficiaries in a single transaction
    /// @dev tokens[i], tranchesList[i], beneficiaries[i] correspond to one vesting
    /// @param tokens Array of token addresses for each vesting
    /// @param tranchesList Array of tranche arrays; each element is the tranche array for the corresponding vesting
    /// @param beneficiaries Addresses to receive each corresponding vesting
    /// @param isSoft Whether the vestings can be cancelled
    /// @param isNftized Whether the vesting NFTs can be minted
    /// @param isTransferable Whether the vesting NFTs can be transferred
    /// @param isTopable Whether the vestings can be topped up
    /// @return Array of created vesting IDs
    function createBulkVestingForBeneficiaries(
        address[] calldata tokens,
        IVestingCalculator.TimeAmount[][] calldata tranchesList,
        address[] calldata beneficiaries,
        bool isSoft,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) external payable returns (uint256[] memory);

    function cancel(uint256 vestingId) external;
    function getVestingSchedule(uint256 vestingId) external view returns (VestingSchedule memory);
    function getVestedAmount(uint256 vestingId) external view returns (uint256);
    function getReleasableAmount(uint256 vestingId) external view returns (uint256);
    function release(uint256 vestingId) external;

    // Fee management functions
    function setFeePercentage(uint256 _feePercentage) external;
    function setFlatFee(uint256 _flatFee) external;
    function setFeeCollector(address newFeeCollector) external;

    // Fee exemption functions
    function setCreatorFeeExempt(address _creator, bool _isExempt) external;
    function setTokenFeeExempt(address _token, bool _isExempt) external;

    // Top-up functions
    function topUpVesting(
        uint256 vestingId,
        IVestingCalculator.TimeAmount[] calldata additionalTranches
    ) external;
}