// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {GPO} from "../gpo/GPO.sol";
import {GPX} from "../gpx/GPX.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721Enumerable} from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {GPVaultNFT} from "../nfts/GPVaultNFT.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

/**
 * @dev Each Staking NFT contains Metadata which contains important details regarding the stake
 *
 * @param id: Unique NFT ID
 * @param gpoStaked: Initial GPO amount staked
 * @param stakingDate: Initial UTC staking time (Unix time stamp in seconds rounded to midnight after the stake)
 *
 */
struct StakingMetadata {
    uint256 id;
    uint256 gpoStaked;
    uint256 stakingDate;
}

/**
 * @title GPOVault — GoldPesa Staking and Conversion Vault
 * @notice This contract allows users to stake GPO tokens in exchange for an NFT that represents their stake.
 * - Over time, the staked GPO is progressively converted into GPX using a daily ecosystem-based allocation model.
 * - Users can later redeem their NFT to receive the remaining GPO and accumulated GPX.
 *
 * @dev Core Features:
 * - Users can stake GPO tokens and mint a unique ERC721 NFT representing the stake.
 * - Each NFT accrues GPX daily based on its proportion of the ecosystem (GPO + GPX).
 * - NFTs can be redeemed at any time to claim unconverted GPO and accrued GPX.
 * - Only the Pawn can convert GPO into GPX over time on a 1:1 basis.
 *
 * @dev Additional Features:
 * - Records daily staking ecosystem metrics to support fair GPX distribution.
 * - Emits structured events for off-chain indexing and analytics.
 * - Users cannot unstake on the same day they staked. Must wait at least 24 hours before unstaking.
 *
 */
contract GPOVault is ERC721Enumerable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =======================
    // ======= ERRORS ========
    // =======================

    /// @dev Thrown when the GPO stake amount is zero
    error GPOAmountMustBeGreaterThanZero();
    /// @dev Thrown when the staking address is invalid (zero address)
    error InvalidStakingAddress();
    /// @dev Thrown when a caller is not the expected token owner
    error NotTokenOwner(address caller, address expectedOwner);
    /// @dev Thrown when the input amount is zero
    error ZeroAmount();
    /// @dev Thrown when a non-Pawn contract attempts an action restricted to the Pawn
    error NotPawn(address caller);
    /// @dev Thrown when a user attempts to unstake on the same day as staking
    error CannotUnstakeOnTheSameDay();

    // =======================
    // ======= EVENTS ========
    // =======================

    /// @notice Emitted when a user stakes GPO tokens into the GoldPesa Vault to mint a NFT.
    /// @param user The address of the user staking GPO.
    /// @param tokenId The ID of the newly minted NFT representing the stake.
    /// @param amount The amount of GPO tokens staked.
    /// @param stakingDate The timestamp corresponding to midnight on the day after the stake.
    event GPOStaked(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 stakingDate
    );

    /// @notice Emitted when an existing NFT is updated with an additional GPO stake.
    /// @param user The address of the user adding to their stake.
    /// @param tokenId The ID of the NFT being updated.
    /// @param additionalAmount The amount of additional GPO tokens added to the existing stake.
    event GPOStakeUpdated(
        address indexed user,
        uint256 indexed tokenId,
        uint256 additionalAmount
    );

    /// @notice Emitted when a user unstakes their NFT and receives GPO and/or GPX tokens.
    /// @param user The address of the user who unstaked.
    /// @param tokenId The ID of the NFT that was unstaked and burned.
    /// @param gpoReturned The amount of GPO tokens returned to the user.
    /// @param gpxReturned The amount of GPX tokens returned to the user.
    event NFTUnstaked(
        address indexed user,
        uint256 indexed tokenId,
        uint256 gpoReturned,
        uint256 gpxReturned
    );

    /// @notice Emitted when GPX tokens are converted into GPO tokens by the Pawn's hourly routine.
    /// @param timestamp The exact block timestamp (unix in seconds) when the conversion took place.
    /// @param pawn The address executing the conversion (Pawn contract).
    /// @param amount The amount of GPX converted.
    /// @param day The current day (block timestamp rounded down to midnight) on which the conversion took place.
    event GPXConvertedToGPO(
        uint256 timestamp,
        address indexed pawn, 
        uint256 amount, 
        uint256 day
    );

    // =================================
    // ========== CONSTANTS ============
    // =================================

    // Seconds in a day (24 hours * 60 minutes * 60 seconds)
    uint256 private constant SECONDS_PER_DAY = 86400;

    // =================================
    // ======= PUBLIC STATE GETTERS ====
    // =================================

    /// @notice GPX
    IERC20 public immutable gpx;
    /// @notice GPO
    IERC20 public immutable gpo;
    /// @notice Total GPO inside vault
    uint256 public totalGPOInsideVault;
    /// @notice The Pawn contract address
    address public pawn;
    /// @notice GPOVault_NFT contract reference for generating token URIs
    GPVaultNFT public immutable gpoVaultNFT;

    // ============================
    // ======= MAPPINGS ===========
    // ============================

    /// @notice Mapping staking NFT ID to StakingMetadata info.
    mapping(uint256 => StakingMetadata) public metadata;

    /// @notice Mapping date (Unix time stamp in seconds) to total GPX staked inside the ecosystem
    mapping(uint256 => uint256) public gpxEco;

    /// @notice Mapping date (Unix time stamp in seconds) to total GPO staked inside the ecosystem
    mapping(uint256 => uint256) public gpoEco;

    /// @notice Mapping date (Unix time stamp in seconds) to GPO staked per day
    mapping(uint256 => uint256) public gpoStakedPerDay;

    // =================================
    // ==== PRIVATE STATE VARIABLES ====
    // =================================

    // Counter for ERC721 tokenID assignment
    uint256 private counter;
    // Deployer address, used for one-time setup operations
    address private immutable deployer;

    // ============================
    // ======== CONSTRUCTOR =======
    // ============================

    /**
     * @notice Deploys the GPOVault contract and initializes token references.
     * @dev Sets the GPO and GPX token addresses and initializes the ERC721 token with name "GoldPesa Vault" and symbol "GPV".
     *
     * @param _gpo The address of the GPO ERC20 token.
     * @param _gpx The address of the GPX ERC20 token.
     * @param _gpVaultNFT The GPVaultNFT contract used for generating token URIs.
     */
    constructor(
        address _gpo,
        address _gpx,
        GPVaultNFT _gpVaultNFT
    ) ERC721("GoldPesa Vault", "GPV") {
        // Set the deployer address to the contract creator
        deployer = msg.sender;

        gpo = IERC20(_gpo);
        gpx = IERC20(_gpx);
        gpoVaultNFT = _gpVaultNFT;
    }

    // ==============================
    // ======= MAIN FUNCTIONS =======
    // ==============================

    /**
     * @notice Retrieves the raw staking metadata for all NFTs owned by a given account.
     * @dev 
     * - Iterates through all tokenIds held by `account` and returns ABI-encoded metadata for each.
     * - If the account holds no tokens, returns an empty byte array.
     *
     * @param account The address of the NFT holder.
     * @return bytes A bytes array containing the concatenated ABI-encoded `StakingMetadata` for each owned token.
     */
    function tokensMetadata(address account) public view returns (bytes memory) {
        // total number of tokens owned by the account
        uint256 tokenCount = balanceOf(account);

        // Return early if account owns no tokens
        if (tokenCount == 0) {
            return new bytes(0);
        }

        bytes memory b = new bytes(0);

        // Iterate over each token held by the account
        for (uint256 i = 0; i < tokenCount; i++) {
            uint256 id = tokenOfOwnerByIndex(account, i);
            StakingMetadata storage nft = metadata[id];

            // Concatenate ABI-encoded metadata to the result
            b = bytes.concat(b, abi.encode(nft));
        }

        return b;
    }

    /**
     * @notice Returns the metadata URI for a given tokenId.
     * @dev Reverts if the token does not exist. Constructs the URI dynamically using staking metadata.
     *
     * @param tokenId The ID of the NFT whose metadata URI is being queried.
     * @return string A string representing the token's metadata URI.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        // Ensure token is minted and owned
        _requireOwned(tokenId);

        // Fetch metadata for tokenId
        StakingMetadata storage meta = metadata[tokenId];

        // Get Current GPO and GPX balances
        (uint256 gpoBalance, uint256 gpxBalance, ) = getStakeBalance(tokenId);

        // Construct Token URI
        return
            gpoVaultNFT.constructTokenURI(
                tokenId,
                meta.gpoStaked,
                meta.stakingDate,
                gpoBalance,
                gpxBalance
            );
    }

    /**
     * @notice Computes the current GPO and GPX balances for a given staking NFT without modifying state.
     * @dev
     * - This is a view-only function that simulates the progressive conversion of GPO to GPX 
     *   from the NFT's staking date up to today (UTC midnight).
     * - Iterates through each staking day, accumulating GPX based on the NFT’s proportional 
     *   share of the GPO + GPX ecosystem on that day.
     * - Stops early if the full GPO amount has been converted to GPX.
     * - Ensures no division by zero if ecosystem values are not initialized for a specific day.
     *
     * @param tokenId The ID of the staking NFT to query.
     *
     * @return gpoBalance The remaining unconverted GPO still held by the NFT.
     * @return gpxBalance The amount of GPX the NFT has accrued so far based on its staking history.
     * @return gpxEcoShareForToday The NFT's share of the GPX converted today
     */
    function getStakeBalance(uint256 tokenId) public view returns (
        uint256 gpoBalance, 
        uint256 gpxBalance,
        uint256 gpxEcoShareForToday
    ) {
        // Ensure the token exists and is owned
        _requireOwned(tokenId);

        // Load the staking metadata
        StakingMetadata storage meta = metadata[tokenId];

        // Get today's UTC midnight timestamp
        uint256 today = block.timestamp - (block.timestamp % SECONDS_PER_DAY);

        // If today is before the staking date, return initial stake
        if (today < meta.stakingDate) {
            return (meta.gpoStaked, 0, 0);
        }

        // Start from the NFT's staking date
        uint256 day = meta.stakingDate;

        // GPO staked for this NFT
        uint256 gpoStaked = meta.gpoStaked;

        // Iterate daily until today, computing the amount converted each day
        while (day <= today) {
            // Get the GPO and GPX ecosystem values for this day
            uint256 ecoTotal = gpoEco[day] + gpxEco[day];
            if (ecoTotal == 0) {
                // Avoid division by zero if ecosystem values are missing
                day += SECONDS_PER_DAY;
                continue;
            }

            // Calculate the GPX amount for this NFT based on its share of the ecosystem on this day
            uint256 amountGPX = FullMath.mulDiv(gpoStaked, gpxEco[day], ecoTotal);

            // Update NFT gpxBalance
            gpxBalance += amountGPX;
            // Deduct NFT GPO Staked Balance
            gpoStaked -= amountGPX;

            // If this is the last day then we need to set the gpxEcoBalanceToday
            if(day == today) {
                gpxEcoShareForToday = amountGPX;
            }
            
            day += SECONDS_PER_DAY; // Move to the next day
        }

        // Set remaining GPO after conversion
        gpoBalance = gpoStaked;
    }

    /**
     * @notice Returns the amount of GPO currently held in the vault that is eligible for conversion to GPX.
     * @dev
     *      - Excludes any GPO staked today
     *      - Assumes `gpoEco[nextDay]` represents today's new GPO that hasn't yet been processed.
     *      - Uses the balance of GPO held by the contract minus unprocessed GPO to determine availability.
     *
     * @return gpoStakedInsideVault The portion of GPO inside the vault that can be converted.
     */
    function maxGPOAvailableForConversion() public view returns (uint256 gpoStakedInsideVault)
    {
        // Get the upcoming UTC midnight timestamp
        uint256 nextDay = block.timestamp + SECONDS_PER_DAY - (block.timestamp % SECONDS_PER_DAY);

        // GPO in vault minus today's staked amount (not yet eligible for conversion)
        gpoStakedInsideVault = totalGPOInsideVault - gpoStakedPerDay[nextDay];
    }

    /**
     * @notice Stakes a specified amount of GPO and mints/updates a staking NFT.
     * @dev
     * - If the user already has a stake for the next-day timestamp, the stake is merged into the existing NFT.
     * - Otherwise, a new staking NFT is minted.
     *
     * @param account The address of the user staking the GPO.
     * @param gpoAmount The amount of GPO tokens to stake.
     *
     * @return uint256 The ID of the staking NFT (either newly minted or updated).
     */
    function stakeGPO(
        address account,
        uint256 gpoAmount
    ) external nonReentrant returns (uint256) {
        // Staking amount must be greater than 0
        if (gpoAmount == 0) {
            revert GPOAmountMustBeGreaterThanZero();
        }

        // Account must not be the zero address
        if (account == address(0)) {
            revert InvalidStakingAddress();
        }

        // Transfer GPO from user to contract
        gpo.safeTransferFrom(msg.sender, address(this), gpoAmount);

        // Align to next UTC day (start of next day in seconds)
        uint256 nextDay = block.timestamp + SECONDS_PER_DAY - (block.timestamp % SECONDS_PER_DAY);

        // Update the GPO Staked Per day
        gpoStakedPerDay[nextDay] += gpoAmount;

        // Update the total GPO inside the vault
        totalGPOInsideVault += gpoAmount;

        // Check if an existing stake for this user and date exists
        (bool overwrite, uint256 idx) = searchContract(account, nextDay);

        if (overwrite) {
            // Update existing stake
            StakingMetadata storage meta = metadata[idx];
            meta.gpoStaked += gpoAmount;

            emit GPOStakeUpdated(account, idx, gpoAmount);

            return idx;
        } else {
            // Mint new staking NFT
            counter += 1;
            uint256 currentId = counter;

            StakingMetadata memory meta = StakingMetadata({
                id: currentId,
                gpoStaked: gpoAmount,
                stakingDate: nextDay
            });

            metadata[currentId] = meta;

            // Mint ERC721 token representing the stake
            _safeMint(account, currentId);

            emit GPOStaked(account, currentId, gpoAmount, nextDay);

            return currentId;
        }
    }

    /**
     * @dev Searches the NFTs for a given address to see if the account is staking multiple times with the same parameters.
     *
     * @param account: Staker address
     * @param start: Staking request start date
     *
     * @return found True if the user has already received a staking NFT with the same parameters as the current staking request.
     * @return idx NFT id that corresponds to the staking NFT that is "found"
     */
    function searchContract(
        address account,
        uint256 start
    ) internal view returns (bool found, uint256 idx) {
        uint256 totalTokens = balanceOf(account);

        if (totalTokens > 0) {
            // Check the last token in the account
            uint256 id = tokenOfOwnerByIndex(account, totalTokens-1);
            StakingMetadata storage meta = metadata[id];

            // If the last token matches the staking date, return it
            if (meta.stakingDate == start) return (true, meta.id);
        }

        return (false, 0);
    }

    /**
     * @notice Unstakes a GoldPesa Vault NFT and distributes the associated GPO and GPX balance to the owner.
     * @dev 
     * - Caller must be the current owner of the NFT.
     * - NFT is burned and staking metadata is deleted after unstaking.
     *
     * @param tokenId The unique token ID of the staking NFT to unstake.
     */
    function unstakeNFT(uint256 tokenId) external nonReentrant {
        // Retrieve the current holder of the NFT
        address holder = _requireOwned(tokenId);

        // Ensure that the caller is the rightful owner
        if (msg.sender != holder) {
            revert NotTokenOwner(msg.sender, holder);
        }

        // Load the staking metadata
        StakingMetadata storage meta = metadata[tokenId];

        // Get today's UTC midnight timestamp
        uint256 today = block.timestamp - (block.timestamp % SECONDS_PER_DAY);

        // Cannot unstake on the same day as staking
        if (today <= meta.stakingDate) {
            revert CannotUnstakeOnTheSameDay();
        }

        // Fetch the current GPO and GPX balances for the NFT
        (uint256 gpoBalance, uint256 gpxBalance, uint256 gpxEcoShareForToday) = getStakeBalance(tokenId);

        // Distribute GPO/GPX to holder
        distributeBalance(holder, gpoBalance, gpxBalance);

        // Update the GPO ecosystem for today
        gpoEco[today] = maxGPOAvailableForConversion();

        // Update the GPX ecosystem for today
        gpxEco[today] -= Math.min(gpxEcoShareForToday, gpxEco[today]);

        // Burn NFT and delete metadata after successful distribution
        _burn(tokenId);
        delete metadata[tokenId];

        emit NFTUnstaked(holder, tokenId, gpoBalance, gpxBalance);
    }

    /**
     * @notice Distributes GPO and GPX balances to the NFT holder.
     * @dev Transfers each token only if its balance is greater than zero.
     *
     * @param holder The address of the NFT owner receiving the tokens.
     * @param gpoBalance The amount of GPO tokens to transfer.
     * @param gpxBalance The amount of GPX tokens to transfer.
     */
    function distributeBalance(
        address holder,
        uint256 gpoBalance,
        uint256 gpxBalance
    ) internal {
        // If GPX balance is greater than the available GPX in the vault, cap it
        if (gpxBalance > gpx.balanceOf(address(this))) {
            gpxBalance = gpx.balanceOf(address(this)); // Limit to available GPX
        }

        // If GPO balance is greater than the available GPO in the vault, cap it
        if (gpoBalance > gpo.balanceOf(address(this))) {
            gpoBalance = gpo.balanceOf(address(this)); // Limit to available GPO
        }   
       
        // Transfer GPX if applicable
        if (gpxBalance > 0) {
            gpx.safeTransfer(holder, gpxBalance);
        }

         // Transfer GPO if applicable
        if (gpoBalance > 0) {
            gpo.safeTransfer(holder, gpoBalance);
        }

        // Update the total GPO inside the vault
        totalGPOInsideVault -= gpoBalance;
    }

    /**
     * @notice Converts GPX to GPO at a 1:1 ratio.
     * @dev
     * - Pawn Smart Contract must approve this contract to convert GPX into GPO
     * - GPX is received from the Pawn Smart Contract and an equal amount of GPO is sent in return.
     * - Ensures the contract has sufficient available GPO to fulfill the swap.
     * - Only callable by the Pawn Smart Contract.
     *
     * @param gpxAmount The amount of GPX tokens to convert.
     * @return uint256 The amount of GPO tokens returned (equal to GPX amount on 1:1 basis).
     */
    function convertGPXtoGPO(
        uint256 gpxAmount
    ) external nonReentrant returns (uint256) {
        // Ensure the caller is the Pawn contract
        if (msg.sender != pawn) {
            revert NotPawn(msg.sender);
        }

        // Ensure the contract has enough GPO available for conversion
        uint256 available = maxGPOAvailableForConversion();
        if (gpxAmount > available) {
            gpxAmount = available; // Limit to available GPO
        }

        // Ensure gpxAmount is greater than zero
        if (gpxAmount == 0) {
            revert ZeroAmount();
        }

        // today's UTC midnight timestamp
        uint256 today = block.timestamp - (block.timestamp % SECONDS_PER_DAY);

        // Update gpoEco for today
        if (gpoEco[today] == 0) {
            // Initialize today's GPO if not already set
            gpoEco[today] = maxGPOAvailableForConversion();
        }

        // Transfer GPX from Pawn to vault
        gpx.safeTransferFrom(msg.sender, address(this), gpxAmount);

        // GPX to GPO conversion is 1:1
        uint256 gpoAmount = gpxAmount;

        // Transfer equal amount of GPO to the Pawn
        gpo.safeTransfer(msg.sender, gpoAmount);

        // Update total GPO inside vault
        totalGPOInsideVault -= gpoAmount;

        // Update gpoEco for today
        gpoEco[today] -= gpoAmount;
        // Update gpxEco for today
        gpxEco[today] += gpxAmount;

        emit GPXConvertedToGPO(block.timestamp, msg.sender, gpxAmount, today);

        return gpoAmount;
    }

    // =============================
    // ======= ONE TIME SET ========
    // =============================

    /**
     * @notice Sets the address of the Pawn contract (one-time operation).
     * @dev
     *      - This function can only be called once; the address is immutable after being set.
     *      - Prevents setting to the zero address.
     *
     * @param _pawn The address of the deployed Pawn contract.
     */
    function setPawnAddress(address _pawn) external {
        require(msg.sender == deployer, "Only deployer can set Pawn address");
        require(pawn == address(0), "Pawn address already set");
        require(_pawn != address(0), "Invalid Pawn address");

        // Set the Pawn contract address
        pawn = _pawn;
    }
}
