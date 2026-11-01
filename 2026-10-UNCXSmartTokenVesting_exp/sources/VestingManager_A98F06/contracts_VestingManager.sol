/// @title VestingManager
// SPDX-License-Identifier: UNLICENSED
// ALL RIGHTS RESERVED
// UNCX by SDDTech reserves all rights on this code. You may not copy these contracts.

pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IVestingManager.sol";
import "./interfaces/IVestingCalculator.sol";
import "./interfaces/IVesting.sol";
import "./interfaces/IERC20Metadata.sol";
import "./interfaces/IVestingSVGGenerator.sol";


/// @notice Main contract for managing vesting schedules
contract VestingManager is ERC721, Ownable2Step, ReentrancyGuard, IVestingManager {
    using SafeERC20 for IERC20;

    // State variables
    /// @notice Calculator contract used for vesting calculations
    IVestingCalculator public immutable calculator;
    /// @notice SVG Generator contract used for NFT metadata
    IVestingSVGGenerator public svgGenerator;
    /// @notice Counter for generating unique vesting IDs
    uint256 public nextVestingId;

    /// @notice Maps token address to total shares
    mapping(address => uint256) private _totalTokenShares;
    /// @notice Maps vesting ID to deposited shares
    mapping(uint256 => uint256) private _depositedShares;

    /// @notice Maps vesting ID to its vesting schedule details
    mapping(uint256 => VestingSchedule) public vestingSchedules;

    /// @notice Maps vesting ID to whether it can be transferred
    mapping(uint256 => bool) private _transferable;

    /// @notice Maps token address to share ratio (starts at 1:1)
    mapping(address => uint256) private _shareRatio;

    /// @notice Fee percentage in basis points (1/100 of 1%)
    uint256 public feePercentage;
    /// @notice Flat fee amount in wei
    uint256 public flatFee;
    /// @notice Address that receives fees
    address public feeCollector;

    /// @notice Mapping of creators exempt from fees
    mapping(address => bool) public feeExemptCreators;
    /// @notice Mapping of tokens exempt from fees
    mapping(address => bool) public feeExemptTokens;


    /// @notice Initializes the contract with a calculator address and SVG generator
    /// @param _calculator Address of the vesting calculator contract
    /// @param _svgGenerator Address of the SVG generator contract
    /// @param _feeCollector Address of the fee collector
    constructor(
        address _calculator, 
        address _svgGenerator, 
        address _feeCollector
    ) ERC721("Vesting NFT", "VNFT") Ownable(msg.sender) {
        if (_calculator == address(0)) revert InvalidCalculator();
        if (_svgGenerator == address(0)) revert InvalidSVGGenerator();
        if (_feeCollector == address(0)) revert InvalidFeeCollector();
        
        calculator = IVestingCalculator(_calculator);
        svgGenerator = IVestingSVGGenerator(_svgGenerator);
        feeCollector = _feeCollector;
    }

    /// @notice Creates a standard linear vesting schedule
    /// @param token Address of the token to vest
    /// @param tranches Array of vesting tranches with time and amount
    /// @param beneficiary Address that will receive the vested tokens
    /// @param isSoft Whether the vesting can be cancelled
    /// @param isNftized Whether the vesting NFT can be minted
    /// @param isTransferable Whether the vesting NFT can be transferred
    /// @param isTopable Whether the vesting can be topped up
    /// @return The ID of the created vesting schedule
    function createVesting(
        address token,
        IVestingCalculator.TimeAmount[] calldata tranches,
        address beneficiary,
        bool isSoft,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) external override payable nonReentrant returns (uint256) {
        return _createVesting(
            token,
            tranches,
            beneficiary,
            isSoft,
            IVesting.VestingType.NORMAL,
            isNftized,
            isTransferable,
            isTopable
        );
    }

    /// @notice Creates a daily soft vesting schedule
    /// @param token Address of the token to vest
    /// @param tranches Array of vesting tranches with time and amount
    /// @param beneficiary Address that will receive the vested tokens
    /// @return The ID of the created vesting schedule
    function createDailySoftVesting(
        address token,
        IVestingCalculator.TimeAmount[] calldata tranches,
        address beneficiary
    ) external payable nonReentrant returns (uint256) {
        return _createVesting(
            token,
            tranches,
            beneficiary,
            true,
            IVesting.VestingType.NORMAL,
            false,
            false,
            true      // Topable by default for daily soft vesting
        );
    }


    /// @notice Creates multiple vesting schedules in a single transaction
    /// @param token Address of the token to vest
    /// @param tranches Array of vesting tranches with time and amount
    /// @param beneficiaries Array of addresses that will receive the vested tokens
    /// @param isSoft Whether the vestings can be cancelled
    /// @param isNftized Whether the vesting NFTs can be minted
    /// @param isTransferable Whether the vesting NFTs can be transferred
    /// @param isTopable Whether the vestings can be topped up
        /// @return Array of created vesting IDs
    // solhint-disable-next-line code-complexity
     function createAirdropVesting(
        address token,
        IVestingCalculator.TimeAmount[] calldata tranches,
        address[] calldata beneficiaries,
        bool isSoft,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) external override payable nonReentrant returns (uint256[] memory) {
        if (beneficiaries.length == 0) revert InvalidArray();
        
        // Compute per-vesting totals
        uint256 totalAmountPer = calculator.getTotalAmount(tranches);
        if (totalAmountPer == 0) revert InvalidAmount();

        bool shouldPayTokenFees = !feeExemptTokens[token] && !feeExemptCreators[msg.sender];
        uint256 tokenFeePer = 0;
        if (shouldPayTokenFees && feePercentage > 0) {
            tokenFeePer = (totalAmountPer * feePercentage) / 10000;
        }
        uint256 netPer = totalAmountPer - tokenFeePer;

        // Handle flat fee once (if configured and not exempt)
        bool shouldPayFlatFee = flatFee > 0 && !feeExemptTokens[token] && !feeExemptCreators[msg.sender];
        if (shouldPayFlatFee) {
            if (msg.value < flatFee) revert InvalidFlatFee();
            (bool success, ) = feeCollector.call{value: flatFee}("");
            if (!success) revert FeeTransferFailed();
            emit FeesCollected(token, 0, flatFee);
        }

        // Lock current share ratio once before minting shares
        _updateShareRatio(token);

        // Transfer all tokens once
        uint256 totalTransferAmount = totalAmountPer * beneficiaries.length;
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalTransferAmount);

        // Transfer aggregated percentage fee once
        if (tokenFeePer > 0) {
            uint256 totalTokenFee = tokenFeePer * beneficiaries.length;
            IERC20(token).safeTransfer(feeCollector, totalTokenFee);
            emit FeesCollected(token, totalTokenFee, 0);
        }
        
        uint256[] memory vestingIds = new uint256[](beneficiaries.length);
        
        for (uint256 i = 0; i < beneficiaries.length; i++) {
            vestingIds[i] = _createVestingPrepaid(
                token,
                tranches,
                beneficiaries[i],
                isSoft,
                IVesting.VestingType.NORMAL,
                isNftized,
                isTransferable,
                isTopable,
                netPer
            );
        }

        emit AirdropVestingCreated(vestingIds, beneficiaries);
        return vestingIds;
    }

    // solhint-disable-next-line code-complexity
    function createBulkVestingForBeneficiary(
        address[] calldata tokens,
        IVestingCalculator.TimeAmount[][] calldata tranchesList,
        address beneficiary,
        bool isSoft,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) external override payable nonReentrant returns (uint256[] memory) {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (tokens.length == 0 || tokens.length != tranchesList.length) revert InvalidArray();

        // Pay flat fee once if applicable
        bool shouldPayFlatFee = flatFee > 0 && !feeExemptCreators[msg.sender];
        if (shouldPayFlatFee) {
            if (msg.value < flatFee) revert InvalidFlatFee();
            (bool success, ) = feeCollector.call{value: flatFee}("");
            if (!success) revert FeeTransferFailed();
            emit FeesCollected(address(0), 0, flatFee);
        }

        // Aggregate per-token totals to minimize transfers and fees
        // totalGrossPerToken[token] => total gross to transfer
        // totalFeePerToken[token] => total percentage fee to collect
        uint256[] memory totalsPerIndex = new uint256[](tokens.length);
        uint256[] memory netPerIndex = new uint256[](tokens.length);

        // First pass: compute gross and net per vesting, and aggregate per token
        // Use local map-like arrays for unique token handling
        address[] memory uniqueTokens = new address[](tokens.length);
        uint256[] memory grossPerToken = new uint256[](tokens.length);
        uint256[] memory feePerToken = new uint256[](tokens.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 gross = calculator.getTotalAmount(tranchesList[i]);
            if (gross == 0) revert InvalidAmount();

            bool shouldPayTokenFees = !feeExemptTokens[token] && !feeExemptCreators[msg.sender];
            uint256 tokenFee = (shouldPayTokenFees && feePercentage > 0)
                ? (gross * feePercentage) / 10000
                : 0;
            uint256 net = gross - tokenFee;

            totalsPerIndex[i] = gross;
            netPerIndex[i] = net;

            // find or add token in uniqueTokens
            uint256 idx = type(uint256).max;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueTokens[j] == token) { idx = j; break; }
            }
            if (idx == type(uint256).max) {
                uniqueTokens[uniqueCount] = token;
                grossPerToken[uniqueCount] = gross;
                feePerToken[uniqueCount] = tokenFee;
                uniqueCount++;
            } else {
                grossPerToken[idx] += gross;
                feePerToken[idx] += tokenFee;
            }
        }

        // Lock share ratio per unique token once
        for (uint256 j = 0; j < uniqueCount; j++) {
            _updateShareRatio(uniqueTokens[j]);
        }

        // Transfer aggregated gross per token once, then send aggregated fee per token
        for (uint256 j = 0; j < uniqueCount; j++) {
            address token = uniqueTokens[j];
            uint256 totalGross = grossPerToken[j];
            uint256 totalFee = feePerToken[j];
            IERC20(token).safeTransferFrom(msg.sender, address(this), totalGross);
            if (totalFee > 0) {
                IERC20(token).safeTransfer(feeCollector, totalFee);
                emit FeesCollected(token, totalFee, 0);
            }
        }

        // Create vestings using prepaid net amounts
        uint256[] memory vestingIds = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            vestingIds[i] = _createVestingPrepaid(
                tokens[i],
                tranchesList[i],
                beneficiary,
                isSoft,
                IVesting.VestingType.NORMAL,
                isNftized,
                isTransferable,
                isTopable,
                netPerIndex[i]
            );
        }

        emit BulkVestingCreated(vestingIds, beneficiary);
        return vestingIds;
    }

    /// @notice Creates multiple vestings for multiple beneficiaries in a single transaction
    /// @dev tokens[i], tranchesList[i], and beneficiaries[i] correspond to one vesting
    // solhint-disable-next-line code-complexity
    function createBulkVestingForBeneficiaries(
        address[] calldata tokens,
        IVestingCalculator.TimeAmount[][] calldata tranchesList,
        address[] calldata beneficiaries,
        bool isSoft,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) external override payable nonReentrant returns (uint256[] memory) {
        if (tokens.length == 0) revert InvalidArray();
        if (tokens.length != tranchesList.length) revert InvalidArray();
        if (tokens.length != beneficiaries.length) revert InvalidArray();

        // Pay flat fee once if applicable (creator-based)
        bool shouldPayFlatFee = flatFee > 0 && !feeExemptCreators[msg.sender];
        if (shouldPayFlatFee) {
            if (msg.value < flatFee) revert InvalidFlatFee();
            (bool success, ) = feeCollector.call{value: flatFee}("");
            if (!success) revert FeeTransferFailed();
            emit FeesCollected(address(0), 0, flatFee);
        }

        // Precompute per-index gross and net, aggregate by token for single transfers and single fee per token
        uint256[] memory totalsPerIndex = new uint256[](tokens.length);
        uint256[] memory netPerIndex = new uint256[](tokens.length);
        
        address[] memory uniqueTokens = new address[](tokens.length);
        uint256[] memory grossPerToken = new uint256[](tokens.length);
        uint256[] memory feePerToken = new uint256[](tokens.length);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            address beneficiary = beneficiaries[i];
            if (beneficiary == address(0)) revert InvalidBeneficiary();

            uint256 gross = calculator.getTotalAmount(tranchesList[i]);
            if (gross == 0) revert InvalidAmount();

            bool shouldPayTokenFees = !feeExemptTokens[token] && !feeExemptCreators[msg.sender];
            uint256 tokenFee = (shouldPayTokenFees && feePercentage > 0)
                ? (gross * feePercentage) / 10000
                : 0;
            uint256 net = gross - tokenFee;

            totalsPerIndex[i] = gross;
            netPerIndex[i] = net;

            // add/aggregate per unique token
            uint256 idx = type(uint256).max;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (uniqueTokens[j] == token) { idx = j; break; }
            }
            if (idx == type(uint256).max) {
                uniqueTokens[uniqueCount] = token;
                grossPerToken[uniqueCount] = gross;
                feePerToken[uniqueCount] = tokenFee;
                uniqueCount++;
            } else {
                grossPerToken[idx] += gross;
                feePerToken[idx] += tokenFee;
            }
        }

        // Lock share ratio per unique token once
        for (uint256 j = 0; j < uniqueCount; j++) {
            _updateShareRatio(uniqueTokens[j]);
        }

        // Transfer aggregated gross per token once, then send aggregated fee per token
        for (uint256 j = 0; j < uniqueCount; j++) {
            address token = uniqueTokens[j];
            uint256 totalGross = grossPerToken[j];
            uint256 totalFee = feePerToken[j];
            IERC20(token).safeTransferFrom(msg.sender, address(this), totalGross);
            if (totalFee > 0) {
                IERC20(token).safeTransfer(feeCollector, totalFee);
                emit FeesCollected(token, totalFee, 0);
            }
        }

        // Create each vesting using the net amount and its beneficiary
        uint256[] memory vestingIds = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            vestingIds[i] = _createVestingPrepaid(
                tokens[i],
                tranchesList[i],
                beneficiaries[i],
                isSoft,
                IVesting.VestingType.NORMAL,
                isNftized,
                isTransferable,
                isTopable,
                netPerIndex[i]
            );
        }

        emit BulkVestingCreatedForBeneficiaries(vestingIds, beneficiaries);
        return vestingIds;
    }

    /// @notice Internal function to create a vesting schedule using a pre-paid/net amount
    /// @dev Skips fee handling and assumes caller has already handled token transfers and fees
    function _createVestingPrepaid(
        address token,
        IVestingCalculator.TimeAmount[] calldata tranches,
        address beneficiary,
        bool isSoft,
        IVesting.VestingType vestingType,
        bool isNftized,
        bool isTransferable,
        bool isTopable,
        uint256 vestingAmount
    ) internal returns (uint256) {
        if (token == address(0)) revert InvalidToken();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (vestingAmount == 0) revert InvalidAmount();

        uint256 vestingId = nextVestingId++;
        _setupVestingSchedule(vestingId, token, beneficiary, vestingAmount, isSoft, vestingType, isNftized, isTopable);
        _setupTranches(vestingId, tranches);
        _setupShares(vestingId, token, vestingAmount);

        if (isNftized) {
            _mint(beneficiary, vestingId);
        }
        _transferable[vestingId] = isTransferable;

        emit VestingCreated(
            vestingId,
            beneficiary,
            token,
            tranches,
            isSoft,
            isTopable,
            isTransferable
        );

        return vestingId;
    }

    /// @notice Internal function to create a vesting schedule
    /// @param token Address of the token to vest
    /// @param tranches Array of vesting tranches with time and amount
    /// @param beneficiary Address that will receive the vested tokens
    /// @param isSoft Whether the vesting can be cancelled
    /// @param vestingType Type of vesting schedule
    /// @param isNftized Whether the vesting NFT can be minted
    /// @param isTransferable Whether the vesting NFT can be transferred
    /// @param isTopable Whether the vesting can be topped up
    /// @return The ID of the created vesting schedule
    function _createVesting(
        address token,
        IVestingCalculator.TimeAmount[] calldata tranches,
        address beneficiary,
        bool isSoft,
        IVesting.VestingType vestingType,
        bool isNftized,
        bool isTransferable,
        bool isTopable
    ) internal returns (uint256) {
        if (token == address(0)) revert InvalidToken();
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        
        _updateShareRatio(token);
        uint256 totalAmount = calculator.getTotalAmount(tranches);
        if (totalAmount == 0) revert InvalidAmount();

        // Handle fee collection and transfers
        uint256 vestingAmount = _handleCreationFees(token, totalAmount);

        // Create vesting schedule
        uint256 vestingId = nextVestingId++;
        _setupVestingSchedule(vestingId, token, beneficiary, vestingAmount, isSoft, vestingType, isNftized, isTopable);
        _setupTranches(vestingId, tranches);
        _setupShares(vestingId, token, vestingAmount);

        // Setup NFT if needed
        if (isNftized) {
            _mint(beneficiary, vestingId);
        }
        _transferable[vestingId] = isTransferable;

        // Update the event emission to include tranches
        emit VestingCreated(
            vestingId,
            beneficiary,
            token,
            tranches,
            isSoft,
            isTopable,
            isTransferable
        );

        return vestingId;
    }

    /// @notice Handles fee calculation and collection for vesting creation
    /// @param token The token address
    /// @param totalAmount The total amount to be vested
    /// @return The amount available for vesting after fees
    function _handleCreationFees(address token, uint256 totalAmount) internal returns (uint256) {
        // Calculate fees based on exemption status
        uint256 tokenFee = 0;
        uint256 flatFeeAmount = 0;
        bool shouldPayTokenFees = !feeExemptTokens[token] && !feeExemptCreators[msg.sender];
        bool shouldPayFlatFee = flatFee > 0 && !feeExemptTokens[token] && !feeExemptCreators[msg.sender];
        
        // Calculate token percentage fee (always applied unless whitelisted)
        if (shouldPayTokenFees && feePercentage > 0) {
            tokenFee = (totalAmount * feePercentage) / 10000;
        }
        
        // Calculate flat fee (optional, only if configured and not whitelisted)
        if (shouldPayFlatFee) {
            flatFeeAmount = flatFee;
        }
        
        // Transfer total amount including fees
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        
        // Transfer token fees to fee collector if any
        if (tokenFee > 0) {
            IERC20(token).safeTransfer(feeCollector, tokenFee);
            emit FeesCollected(token, tokenFee, 0);
        }
        
        // Transfer flat fee in ETH if any
        if (flatFeeAmount > 0) {
            if (msg.value < flatFeeAmount) revert InvalidFlatFee();
            (bool success, ) = feeCollector.call{value: flatFeeAmount}("");
            if (!success) revert FeeTransferFailed();
            emit FeesCollected(token, 0, flatFeeAmount);
        }

        // Return the amount available for vesting (after token fees)
        return totalAmount - tokenFee;
    }



    function _setupVestingSchedule(
        uint256 vestingId,
        address token,
        address beneficiary,
        uint256 totalAmount,
        bool isSoft,
        IVesting.VestingType vestingType,
        bool isNftized,
        bool isTopable
    ) internal {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        schedule.token = token;
        schedule.creator = msg.sender;
        schedule.beneficiary = beneficiary;
        schedule.totalAmount = totalAmount;
        schedule.isSoft = isSoft;
        schedule.isNftized = isNftized;
        schedule.isTopable = isTopable;
        schedule.released = 0;
        schedule.cancelled = false;
        schedule.vestingType = vestingType;
    }

    function _setupTranches(
        uint256 vestingId,
        IVestingCalculator.TimeAmount[] calldata tranches
    ) internal {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        for (uint256 i = 0; i < tranches.length; i++) {
            schedule.tranches.push(tranches[i]);
        }
    }

    function _setupShares(
        uint256 vestingId,
        address token,
        uint256 totalAmount
    ) internal {
        // Add offset to total shares to prevent inflation attacks
        uint256 shares = _toShares(token, totalAmount);
        _depositedShares[vestingId] = shares;
        _totalTokenShares[token] += shares;
    }

    /// @notice Cancels a soft vesting schedule
    /// @param vestingId ID of the vesting schedule to cancel
    function cancel(uint256 vestingId) external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        if (schedule.creator != msg.sender) revert NotAuthorized();
        if (!schedule.isSoft) revert NotCancellable();
        if (schedule.cancelled) revert VestingAlreadyCancelled();

        uint256 vestedAmount = getVestedAmount(vestingId);
        uint256 remainingAmount = schedule.totalAmount - vestedAmount;
        
        // Calculate vested shares with proper handling for edge cases
        uint256 vestedShare;
        if (schedule.totalAmount == 0) {
            vestedShare = 0;
        } else {
            vestedShare = vestedAmount * _depositedShares[vestingId] / schedule.totalAmount;
            // Ensure vestedShare doesn't exceed deposited shares due to rounding
            if (vestedShare > _depositedShares[vestingId]) {
                vestedShare = _depositedShares[vestingId];
            }
        }

        // Update total shares safely
        uint256 sharesToRemove = _depositedShares[vestingId] - vestedShare;
        if (sharesToRemove > 0) {
            _totalTokenShares[schedule.token] -= sharesToRemove;
        }
        
        _depositedShares[vestingId] = vestedShare;

        schedule.cancelled = true;
        schedule.totalAmount = vestedAmount;

        if (remainingAmount > 0) {
            IERC20(schedule.token).safeTransfer(schedule.creator, remainingAmount);
        }

        emit VestingCancelled(vestingId);
    }

    /// @notice Gets the full vesting schedule for a given ID
    /// @param vestingId ID of the vesting schedule
    /// @return The complete vesting schedule
    function getVestingSchedule(uint256 vestingId) external view override returns (VestingSchedule memory) {
        return vestingSchedules[vestingId];
    }

    /// @notice Calculates the total amount vested at current time
    /// @param vestingId ID of the vesting schedule
    /// @return The total amount vested
    function getVestedAmount(uint256 vestingId) public view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        if (schedule.cancelled) return schedule.totalAmount;
        
        uint256 rawVestedAmount = calculator.calculateVestedAmount(
            schedule.tranches,
            block.timestamp
        );

        // Return raw amount - no need to convert to shares and back
        return rawVestedAmount;
    }

    /// @notice Calculates the amount that can be released
    /// @param vestingId ID of the vesting schedule
    /// @return The amount that can be released
    function getReleasableAmount(uint256 vestingId) public view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        uint256 releasableShares = _getReleasableShares(vestingId);
        return _toAmount(schedule.token, releasableShares);
    }

    /// @notice Releases vested tokens to the beneficiary
    /// @param vestingId ID of the vesting schedule
    function release(uint256 vestingId) external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        
        if (schedule.isNftized) {
            if (msg.sender != ownerOf(vestingId)) revert NotAuthorized();
        } else {
            if (msg.sender != schedule.beneficiary) revert NotAuthorized();
        }

        // Update ratio before calculating releasable shares
        _updateShareRatio(schedule.token);

        // Get releasable shares using the consistent calculation method
        uint256 releasableShares = _getReleasableShares(vestingId);
        if (releasableShares == 0) revert NoTokensToRelease();

        // Calculate amount proportional to shares
        uint256 balance = IERC20(schedule.token).balanceOf(address(this));
        uint256 amount = (releasableShares * balance) / _totalTokenShares[schedule.token];

        // Update shares state
        schedule.released += releasableShares;
        _totalTokenShares[schedule.token] -= releasableShares;

        // Transfer tokens
        IERC20(schedule.token).safeTransfer(msg.sender, amount);

        emit TokensReleased(vestingId, msg.sender, amount);
    }

    /// @notice Override of ERC721 _update to enforce transferability rules
    /// @param to Address to transfer to
    /// @param tokenId ID of the token being transferred
    /// @param auth Address authorized to make the transfer
    /// @return The from address_
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        address from = super._update(to, tokenId, auth);
        
        // Skip transferability check for mints and burns
        if (from != address(0) && to != address(0)) {
            if (!_transferable[tokenId]) {
                revert NonTransferableToken();
            }
            // Update beneficiary for actual transfers
            VestingSchedule storage schedule = vestingSchedules[tokenId];
            schedule.beneficiary = to;
        }else if(to == address(0)){
            VestingSchedule storage schedule = vestingSchedules[tokenId];
            schedule.isNftized = false;
        }

        return from;
    }

    /// @notice Allows beneficiary to mint their vesting NFT if not already minted
    /// @param vestingId ID of the vesting schedule to mint NFT for
    function mintVestingNFT(uint256 vestingId) external {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        
        // Only beneficiary can mint
        if (msg.sender != schedule.beneficiary) revert NotAuthorized();
        if (schedule.isNftized) revert NFTAlreadyMinted();
        
        // Set NFT as minted before actual mint to prevent reentrance
        schedule.isNftized = true;
        
        // Mint NFT to beneficiary
        _mint(schedule.beneficiary, vestingId);
    }

    /// @notice Transfers a vesting schedule to a new beneficiary
    /// @param vestingId ID of the vesting schedule to transfer
    /// @param newBeneficiary Address of the new beneficiary
    function transferVesting(uint256 vestingId, address newBeneficiary) external {
        if (newBeneficiary == address(0)) revert InvalidBeneficiary();
        
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        
        // Only current beneficiary can transfer
        if (msg.sender != schedule.beneficiary) revert NotAuthorized();

        if (schedule.isNftized) {
            super._update( newBeneficiary, vestingId,address(0));
        }
        
        // If not NFTized, just update beneficiary
        schedule.beneficiary = newBeneficiary;

        emit VestingTransferred(vestingId, msg.sender, newBeneficiary);
    }

    /// @notice Tops up a vesting schedule with additional tranches
    /// @param vestingId ID of the vesting to top up
    /// @param additionalTranches Array of additional vesting tranches
    function topUpVesting(
        uint256 vestingId,
        IVestingCalculator.TimeAmount[] calldata additionalTranches
    ) external nonReentrant {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        
        _validateTopUpAuthorization(schedule);
        _validateTopUpTranches(schedule, additionalTranches);
        
        uint256 topUpAmount = _calculateTopUpAmount(schedule, additionalTranches);
        
        uint256 actualTopUpAmount = _processTopUpTransfer(schedule, topUpAmount);
        _updateTopUpState(schedule, vestingId, additionalTranches, actualTopUpAmount);
        
        emit VestingToppedUp(vestingId, msg.sender, actualTopUpAmount, additionalTranches);
    }

    /// @notice Validates authorization for top-up operation
    function _validateTopUpAuthorization(VestingSchedule storage schedule) internal view {
        if(msg.sender != schedule.creator) revert NotAuthorized();
        if(schedule.cancelled) revert VestingAlreadyCancelled();
        if(!schedule.isTopable) revert NotTopable();
    }

    /// @notice Validates the additional tranches for top-up
    function _validateTopUpTranches(
        VestingSchedule storage schedule, 
        IVestingCalculator.TimeAmount[] calldata additionalTranches
    ) internal view {
        uint256 lastTime = schedule.tranches[schedule.tranches.length - 1].time;
        if (additionalTranches[0].time <= lastTime) revert InvalidTime();

        uint256 newFinalAmount = calculator.getTotalAmount(additionalTranches);
        if (newFinalAmount <= schedule.totalAmount) revert InvalidAmount();
        if (additionalTranches[0].amount < schedule.totalAmount) revert InvalidAmount();
    }

    /// @notice Calculates the top-up amount
    function _calculateTopUpAmount(
        VestingSchedule storage schedule, 
        IVestingCalculator.TimeAmount[] calldata additionalTranches
    ) internal view returns (uint256) {
        uint256 newFinalAmount = calculator.getTotalAmount(additionalTranches);
        return newFinalAmount - schedule.totalAmount;
    }



    /// @notice Processes the token transfer for top-up
    function _processTopUpTransfer(VestingSchedule storage schedule, uint256 topUpAmount) internal returns (uint256) {
        _updateShareRatio(schedule.token);

        // Calculate percentage fee for top-up if not whitelisted
        uint256 tokenFee = 0;
        bool shouldPayTokenFees = !feeExemptTokens[schedule.token] && !feeExemptCreators[msg.sender];
        
        if (shouldPayTokenFees && feePercentage > 0) {
            tokenFee = (topUpAmount * feePercentage) / 10000;
        }
        
        // Transfer the full amount including fees
        uint256 totalTransferAmount = topUpAmount + tokenFee;
        uint256 balanceBefore = IERC20(schedule.token).balanceOf(address(this));
        IERC20(schedule.token).safeTransferFrom(msg.sender, address(this), totalTransferAmount);
        uint256 actualReceived = IERC20(schedule.token).balanceOf(address(this)) - balanceBefore;
        
        // Transfer token fees to fee collector if any
        if (tokenFee > 0) {
            IERC20(schedule.token).safeTransfer(feeCollector, tokenFee);
            emit FeesCollected(schedule.token, tokenFee, 0);
        }
        
        // Return the actual amount for vesting (excluding fees)
        return actualReceived - tokenFee;
    }

    /// @notice Updates the vesting state after top-up
    function _updateTopUpState(
        VestingSchedule storage schedule, 
        uint256 vestingId, 
        IVestingCalculator.TimeAmount[] calldata additionalTranches, 
        uint256 actualTopUpAmount
    ) internal {
        uint256 newFinalAmount = calculator.getTotalAmount(additionalTranches);
        uint256 newShares = _toShares(schedule.token, actualTopUpAmount);

        schedule.totalAmount = newFinalAmount;
        _depositedShares[vestingId] += newShares;
        _totalTokenShares[schedule.token] += newShares;

        for (uint256 i = 0; i < additionalTranches.length; i++) {
            schedule.tranches.push(additionalTranches[i]);
        }
    }

    function _toShares(address token, uint256 amount) internal view returns (uint256) {
        return (amount * _shareRatio[token]) / 1e18;
    }

    function _toAmount(address token, uint256 shares) internal view returns (uint256) {
        return (shares * 1e18) / _shareRatio[token];
    }

    function _getReleasableShares(uint256 vestingId) public view returns (uint256) {
        VestingSchedule storage schedule = vestingSchedules[vestingId];
        if (schedule.cancelled) {
            return _depositedShares[vestingId] - schedule.released;
        }

        // Get raw vested amount
        uint256 rawVestedAmount = calculator.calculateVestedAmount(
            schedule.tranches,
            block.timestamp
        );

        // Cap at total amount
        if (rawVestedAmount > schedule.totalAmount) {
            rawVestedAmount = schedule.totalAmount;
        }

        // Convert amount to shares with higher precision
        uint256 vestedShares;
        if (schedule.totalAmount == 0) {
            vestedShares = 0;
        } else {
            // First multiply deposited shares by vested amount to maintain precision
            uint256 vestedSharesTimesPrecision = _depositedShares[vestingId] * rawVestedAmount;
            // Then divide by total amount
            vestedShares = vestedSharesTimesPrecision / schedule.totalAmount;
        }
        
        // Cap at deposited shares
        if (vestedShares > _depositedShares[vestingId]) {
            vestedShares = _depositedShares[vestingId];
        }

        // Calculate releasable shares
        if (vestedShares <= schedule.released) return 0;
        return vestedShares - schedule.released;
    }

    function _updateShareRatio(address token) internal {
        uint256 totalShares = _totalTokenShares[token];       
        if(totalShares == 0){
            _shareRatio[token] = 1e18;
            return;
        }
        uint256 balance = IERC20(token).balanceOf(address(this));

        // Handle edge case where balance is very low to prevent overflow
        if (balance == 0) {
            _shareRatio[token] = 1e18;
            return;
        }

        // Calculate share ratio with overflow protection
        uint256 numerator = (totalShares + 1) * 1e18;
        uint256 denominator = balance + 1;
        
        // Ensure we don't have division by zero and handle overflow
        if (denominator == 0) {
            _shareRatio[token] = 1e18;
        } else {
            _shareRatio[token] = numerator / denominator;
        }
    }

    /// @notice Set the fee percentage
    /// @param _feePercentage New fee percentage in basis points
    function setFeePercentage(uint256 _feePercentage) external onlyOwner {
        if (_feePercentage > 500) revert InvalidFeePercentage(); // Max 5%
        feePercentage = _feePercentage;
        emit FeePercentageUpdated(_feePercentage);
    }

    /// @notice Set the flat fee
    /// @param _flatFee New flat fee amount in wei
    function setFlatFee(uint256 _flatFee) external onlyOwner {
        flatFee = _flatFee;
        emit FlatFeeUpdated(_flatFee);
    }

    /// @notice Set whether a creator is exempt from fees
    /// @param _creator Creator address to update
    /// @param _isExempt Whether the creator should be exempt from fees
    function setCreatorFeeExempt(address _creator, bool _isExempt) external onlyOwner {
        feeExemptCreators[_creator] = _isExempt;
        emit CreatorFeeExemptionUpdated(_creator, _isExempt);
    }

    /// @notice Set whether a token is exempt from fees
    /// @param _token Token address to update
    /// @param _isExempt Whether the token should be exempt from fees
    function setTokenFeeExempt(address _token, bool _isExempt) external onlyOwner {
        feeExemptTokens[_token] = _isExempt;
        emit TokenFeeExemptionUpdated(_token, _isExempt);
    }

    /// @notice Set the fee collector
    /// @param newFeeCollector Address of the new fee collector
    function setFeeCollector(address newFeeCollector) external onlyOwner {
        if (newFeeCollector == address(0)) revert InvalidFeeCollector();
        address oldFeeCollector = feeCollector;
        feeCollector = newFeeCollector;
        emit FeeCollectorUpdated(oldFeeCollector, newFeeCollector);
    }

    /// @notice Set the SVG generator contract
    /// @param newSVGGenerator Address of the new SVG generator contract
    function setSVGGenerator(address newSVGGenerator) external onlyOwner {
        if (newSVGGenerator == address(0)) revert InvalidSVGGenerator();
        address oldSVGGenerator = address(svgGenerator);
        svgGenerator = IVestingSVGGenerator(newSVGGenerator);
        emit SVGGeneratorUpdated(oldSVGGenerator, newSVGGenerator);
    }

    /// @notice Returns the token URI for a given vesting NFT
    /// @param tokenId The vesting ID
    /// @return The token URI containing SVG metadata
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (ownerOf(tokenId) == address(0)) revert TokenDoesNotExist();
        
        VestingSchedule storage schedule = vestingSchedules[tokenId];
        (string memory tokenSymbol, string memory tokenName, uint8 tokenDecimals) = _getTokenMetadata(schedule.token);
        
        // Calculate start and end times from tranches
        uint256 startTime = schedule.tranches.length > 0 ? 
            schedule.tranches[0].time : block.timestamp;
        uint256 endTime = schedule.tranches.length > 0 ? 
            schedule.tranches[schedule.tranches.length - 1].time : block.timestamp;
        
        // Calculate vested amount (available to claim)
        uint256 vestedAmount = getVestedAmount(tokenId);
        
        return svgGenerator.generateTokenURI(
            tokenId,
            tokenSymbol,
            tokenName,
            schedule.totalAmount,
            vestedAmount,
            startTime,
            endTime,
            schedule.isSoft,
            schedule.isTopable,
            schedule.beneficiary,
            tokenDecimals
        );
    }

    /// @notice Gets comprehensive token metadata from the token contract
    /// @param token The token address
    /// @return symbol The token symbol
    /// @return name The token name
    /// @return decimals The token decimals
    function _getTokenMetadata(address token) internal view returns (
        string memory symbol, 
        string memory name, 
        uint8 decimals
    ) {
        try IERC20Metadata(token).symbol() returns (string memory _symbol) {
            symbol = _symbol;
        } catch {
            symbol = "TOKEN";
        }
        
        try IERC20Metadata(token).name() returns (string memory _name) {
            name = _name;
        } catch {
            name = symbol; // Fall back to symbol if name fails
        }
        
        try IERC20Metadata(token).decimals() returns (uint8 _decimals) {
            decimals = _decimals;
        } catch {
            decimals = 18; // Default to 18 decimals
        }
    }
}   