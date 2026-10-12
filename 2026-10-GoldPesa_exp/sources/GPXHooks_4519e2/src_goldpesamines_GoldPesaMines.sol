// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { VRFConsumerBaseV2Plus } from "chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import { VRFV2PlusClient } from "chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { ERC721Enumerable } from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import { ERC721Burnable } from "openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import { ERC721 } from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Queue } from "../utils/Queue.sol";
import { GPMTreasury } from "./GPMTreasury.sol";
import { MinesNFT } from "../nfts/MinesNFT.sol";
import { GPX } from "../gpx/GPX.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { GPXOwner } from "../gpxowner/GPXOwner.sol";

/**
 * @notice Metadata associated with each GoldPesa Miner NFT.
 *
 * @param id            The unique NFT ID.
 * @param positionList  Index of the NFT within its current level's player list.
 * @param currentLevel  The current level of the miner within the GoldPesa Mine
 * @param gpxBalance    The GPX staking balance allocated to the miner upon entry.
 */
struct MiningNFT {
    uint256 id;
    uint256 positionList;
    int8 currentLevel;
    uint256 gpxBalance;
}

/**
 * @title GoldPesa Mines Contract (GPM)
 * @notice Core contract for the GoldPesa Mines game.
 *
 * @dev This contract implements a gamified NFT-based mining experience where players mint GoldPesa Miner NFTs,
 *      each representing a miner that can ascend through multiple levels of a virtual mine. 
 *
 * Key Features:
 * - Minting: Players receive NFT miners with a GPX staking balance
 * - Ascension: Miners move through levels using a Chainlink VRF-powered random selection mechanism.
 * - Level Distribution: Each level is allocated 10% of the total GPX wealth of the mine
 * - Awards Distribution: Miners equally share the GPX wealth of their current level.
 * - VRF Integration: Ensures randomness and fairness when selecting miners for level ascension.
 * - Metadata Tracking: Each NFT tracks level, position in level, and GPX staking balance.
 * - Treasury Integration: Interacts with the GPMTreasury contract to manage funds, staking, and approvals.
 * - Automation: Supports automated ascension via queue management and Chainlink randomness fulfillment.
 *
 */
contract GoldPesaMines is ERC721Burnable, ERC721Enumerable, VRFConsumerBaseV2Plus {
    using Queue for Queue.Uint256Queue;

    // =======================
    // ======= ERRORS ========
    // =======================

    /// @notice Thrown when a caller is not an authorized address.
    /// @param have The address that attempted the call.
    /// @param authorized The expected authorized address.
    error OnlyAuthorized(address have, address authorized);

    /// @notice Thrown when a function restricted to the VRF owner is called by another address.
    /// @param have The address that attempted the call.
    /// @param owner The address of the current VRF owner.
    error OnlyVRFOwner(address have, address owner);

    /// @notice Thrown when an invalid index is accessed in an array.
    /// @param index The index that was accessed.
    /// @param length The length of the array at the time of access.
    error IndexOutOfBounds(uint256 index, uint256 length);

    /// @notice Thrown when a Chainlink VRF request is attempted without a valid subscription ID set.
    error SubscriptionIdNotSet();

    /// @notice Thrown when a batch minting function is called with a batch size of zero.
    error BatchSizeZero();

    // =======================
    // ======= EVENTS ========
    // =======================

    /// @notice Emitted when a new GoldPesa Miner NFT is minted
    /// @param account The address receiving the minted NFT
    /// @param token The ID of the newly minted NFT
    /// @param gpxBalance The initial GPX balance staked to the NFT
    event NFTMinted(address indexed account, uint256 token, uint256 gpxBalance);

    /// @notice Emitted when an NFT ascends to a higher level in the GoldPesa Mine
    /// @param account The owner of the NFT being ascended
    /// @param token The ID of the NFT that ascended
    /// @param toLevel The new level the NFT has reached
    event Ascension(address indexed account, uint256 token, int8 toLevel);

    /// @notice Emitted when the metadata of a GoldPesa Miner NFT is updated
    /// @param tokenId The ID of the NFT whose metadata was modified
    event MetadataUpdate(uint256 tokenId);

    /// @dev Emitted when a Chainlink VRF request is made
    /// @param requestId The ID of the VRF request
    /// @param batchSize The number of random words requested in this batch
    /// @param vrfCounter The total number of outstanding VRF words requested so far
    event VRFRequested(uint256 requestId, uint256 batchSize, uint256 vrfCounter);

    /// @dev Emitted when Chainlink VRF fulfills a request
    /// @param count The number of random words fulfilled in this batch
    /// @param vrfCounterRemaining The remaining count of outstanding VRF words after fulfillment
    event VRFFulfilled(uint256 count, uint256 vrfCounterRemaining);

    // =================================
    // ========== CONSTANTS ============
    // =================================

    /// @notice Maximum level in the mine
    int8 public constant MAX_LEVEL = 11;

    // ============================
    // ======= PUBLIC STATE  ======
    // ============================

    /// @notice GPMT contract
    GPMTreasury public immutable gpmt;
    /// @notice GPX contract
    IERC20 public immutable gpx;
    /// @notice GPXOwner 
    GPXOwner public immutable gpxOwner;
    /// @notice Holds the current outstanding words requested via vrf and waiting to be received
    uint256 public vrfCounter; 
    /// @notice GPMMines NFT contract
    MinesNFT public immutable gpMinesNFT;

    // ============================
    // ======= MAPPINGS ===========
    // ============================

    /// @notice MiningNFT Metadata for a given GoldPesa Miner NFT token ID
    mapping(uint256 => MiningNFT) public metadata;

    /// @notice Number of players on each level
    mapping(int8 => uint256[]) private levels;

    // =================================
    // ==== PRIVATE STATE VARIABLES ====
    // =================================

    /// @notice Define a tokens Queue and random number Queue 
    Queue.Uint256Queue private tokensQueue;
    Queue.Uint256Queue private randomNumbersQueue;

    /// @notice Counter for ERC721 tokenID assignment 
    uint256 private counter;

    /// @notice The decimal number which represents the bitwise position of the players in the GoldPesa Mine
    uint256 private levelCounter;

    // =================================
    // ========== MODIFIERS ============
    // =================================

    /// @notice Authorize only GPMTreasury contract
    modifier onlyAuthorized {
        if (msg.sender != address(gpmt)) 
            revert OnlyAuthorized(msg.sender, address(gpmt));
        _;
    }
    
    /// @notice Ensures the caller is the VRF owner.
    modifier onlyVRFOwner() {
        if (msg.sender != owner()) 
            revert OnlyVRFOwner(msg.sender, owner());
        _;
    }

    // ============================
    // ======== CONSTRUCTOR =======
    // ============================

    /**
     * @dev Contract constructor for initializing the GoldPesa Mines.
     * 
     * Initializes core settings for the game, including:
     * - The GPX and USDC token addresses used for staking
     * - The Uniswap quoter and pool key for liquidity-related operations.
     * - The Chainlink VRF coordinator for randomness during ascension.
     * - The instantiation of the GoldPesa Treasury contract.
     * - The initialization of internal token and randomness queues.
     *
     * @param _gpx GPX token address
     * @param _usdc USDC token address
     * @param _quoter Uniswap V4 Quoter address
     * @param _gpxPoolKey GPX Pool Key containing pool information
     * @param _vrfCoordinatorV2Plus Chainlink VRF 2.5 Coordinator address
     * @param _permit2 Permit2 contract address for approvals
     * @param _router Uniswap V4 Universal Router address
     * @param _gpxOwner Instance of GPXOwner contract
     * @param _stateview Uniswap V4 StateView address
     * @param _minesNFT Mines_NFT contract for NFT token uri generation
     */
    constructor(
        address _gpx,
        address _usdc,
        address _quoter,
        PoolKey memory _gpxPoolKey,
        address _vrfCoordinatorV2Plus,
        address _permit2,
        address _router,
        GPXOwner _gpxOwner,
        address _stateview,
        MinesNFT _minesNFT
    ) ERC721 ("GoldPesa Mines", "GPM") VRFConsumerBaseV2Plus(_vrfCoordinatorV2Plus) {
        require(_gpx != address(0) && _usdc != address(0) && _quoter != address(0) &&
            _permit2 != address(0) && _router != address(0) && _stateview != address(0), "Invalid Address");

        // Set the GoldPesa Mines NFT contract
        gpMinesNFT = _minesNFT;
        
        // Initialize the Queues
        tokensQueue.initialize();
        randomNumbersQueue.initialize();

        // Deploy GoldPesa Treasury Contract
        gpmt = new GPMTreasury(
            _gpx, 
            _usdc, 
            address(this), 
            _quoter, 
            _gpxPoolKey, 
            _router, 
            _permit2,
            _gpxOwner,
            _stateview
        );

        // Instance of GPX
        gpx = IERC20(_gpx);

        // Set GPX Owner
        gpxOwner = _gpxOwner;
    }

    // ============================
    // ======= MAIN FUNCTION ======
    // ============================

    /**
     * @notice Returns the combined GPX balance for a specific NFT.
     * @dev 
     * This is the sum of:
     *      1) The GPX originally staked to the NFT (gpxBalance), and
     *      2) The GPX earnings it is currently entitled to based on its level.
     * This function will revert if `tokenId` does not exist
     *
     * @param tokenId The ID of the GoldPesa Miner NFT to query.
     * @return totalGPX The total GPX amount (stake + level rewards) for the given `tokenId`.
     */
    function getTotalGPXBalance(uint256 tokenId) public view returns (uint256 totalGPX) {
        // Ensure the token exists
        _requireOwned(tokenId);

        // Fetch on‐chain metadata for this NFT
        MiningNFT storage meta = metadata[tokenId];

        // Sum the NFT’s original GPX stake plus its current level’s rewards
        totalGPX = meta.gpxBalance + gpxTotalPrizeAt(meta.currentLevel);
    }

    /**
     * @notice Calculates the GPX reward allocated to each miner at a specific level.
     * @dev
     *  - Retrieves the total GPX earnings held by the treasury contract (`gpmt`), 
     *    subtracting any GPX currently staked (so only unallocated GPX is considered).
     *  - Divides the total GPX earnings equally across 10 levels (1 - 10).
     *  - If no miners exist at the given `level`, returns the per‐level share directly.
     *  - If there are miners at the given `level`, divides that per‐level share by the number 
     *    of miners in `levels[level]` to determine each miner’s reward.
     *
     * @param level The target level in the GoldPesa Mines (0 ≤ level < MAX_LEVEL).
     * @return rewardGPX The amount of GPX each miner at the specified level will receive.
     */
    function gpxTotalPrizeAt(int8 level) public view returns (uint256 rewardGPX) {
        // If the requested level is 0 or out of bounds, there are no rewards.
        if (level <= 0 || level >= MAX_LEVEL) {
            return 0;
        }

        // Compute the total GPX Earnings:
        (uint256 totalGPXEarnings, ) = gpmt.getTotalMineEarnings();

        // Divide that pool equally across levels 1-10 - Not including level 0.
        uint256 totalGPXEarningsPerLevel = totalGPXEarnings / uint256(uint8(MAX_LEVEL-1));

        // If no miners are on this level, return the full per‐level share.
        if (levels[level].length == 0) {
            return totalGPXEarningsPerLevel;
        } else {
            // Split the per‐level pool by the number of miners at this level.
            return totalGPXEarningsPerLevel / levels[level].length;
        }
    }

    /**
     * @notice Returns the metadata URI for a given NFT, including its current level and USDC value.
     * @dev
     *  - Verifies that `tokenId` exists
     *  - Fetches the NFT’s on‐chain metadata (`MiningNFT`), 
     *  - Computes its total USDC value
     *  - Constructs the final tokenURI using the `gpMinesNFT` contract.
     *
     * @param tokenId The ID of the GoldPesa Miner NFT.
     * @return string A string containing the tokenURI for the specified NFT.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        // Ensure the NFT exists 
        _requireOwned(tokenId);

        // Load stored metadata for this NFT
        MiningNFT storage meta = metadata[tokenId];

        // Compute the NFT’s total USDC value (GPX stake + level‐based prize, converted to USDC)
        uint256 nftValueInUSDC = gpmt.getTotalNFTValueInUSDC(tokenId);

        // Construct and return the final tokenURI
        return gpMinesNFT.constructTokenURI(
            tokenId,
            meta.currentLevel,
            nftValueInUSDC
        );
    }

    /**
     * @notice Retrieves the current number of miners at each level of the mine.
     * @dev
     *  - Iterates through levels 0 up to (but not including) MAX_LEVEL.
     *  - Reads `levels[i].length` to determine how many NFTs are queued at level `i`.
     *  - Populates a fixed-size array of length 16.
     *  - This allows frontends or off‐chain scripts to quickly display occupancy per level.
     *
     * @return counts A `uint256[16]` array where `counts[i]` is the number of miners at level `i`.
     */
    function getCountPlayers() public view returns (uint256[16] memory counts) {
        for (int8 i = 0; i < MAX_LEVEL; i++) {
            counts[uint256(uint8(i))] = levels[i].length;
        }
        return counts;
    }

    /**
     * @notice Retrieves raw metadata for all NFTs owned by a specific address.
     *
     * @dev
     *  - Determine how many tokens the account owns.
     *  - If the account holds no tokens, returns an empty byte array.
     *  - Loops through each token ID owned by `account` (via `tokenOfOwnerByIndex`)
     *    and reads its corresponding `MiningNFT` struct from `metadata`.
     *  - ABI-encodes each `MiningNFT` struct and concatenates them into a single `bytes` array.
     *  - Consumers can decode the returned bytes offline by repeatedly decoding consecutive `MiningNFT` entries.
     *
     * @param account The address whose NFT metadata should be returned.
     * @return bytes A dynamic `bytes` array containing the ABI-encoded `MiningNFT` structs for each token owned by `account`.
     */
    function tokensMetadata(address account) public view returns (bytes memory) {
        // Determine how many NFTs account owns
        uint256 tokenCount = balanceOf(account);

        // If the account holds no tokens, return an empty byte array
        if (tokenCount == 0) {
            return new bytes(0);
        }
        
        // Initialize an empty bytes array to accumulate encoded metadata
        bytes memory b = new bytes(0);

        // Iterate over each token the account owns
        for (uint256 i = 0; i < tokenCount; i++) {
            // Fetch the token ID at index i in the owner's enumeration
            uint256 id = tokenOfOwnerByIndex(account, i);

            // Load the `MiningNFT` struct for this token ID
            MiningNFT storage nft = metadata[id];

            // ABI-encode the struct and append to `b`
            b = bytes.concat(
                b,
                abi.encodePacked(
                    nft.id,
                    nft.currentLevel,
                    nft.gpxBalance
                )
            );
        }

        // Return the concatenated metadata for all owned tokens
        return b;
    }

    /**
     * @notice Mints a batch of GoldPesa Miner NFTs to a specified account.
     *
     * @dev
     *  - Only callable by the authorized GPMTreasury contract (via the `onlyAuthorized` modifier).
     *  - Splits the total GPX to be staked (`totalGPX`) equally among all minted NFTs.
     *  - For each new NFT:
     *      1. Increment the internal `counter` to generate a unique token ID.
     *      2. Construct a `MiningNFT` struct with:
     *         - `id`: the newly assigned token ID.
     *         - `positionList`: initialized to 0 (will be set during ascension).
     *         - `currentLevel`: set to `-1`, indicating pre-ascension state.
     *         - `gpxBalance`: the per-NFT GPX stake (`totalGPX / batchSize`).
     *      3. Mint the ERC-721 token to `account`.
     *      4. Store the `MiningNFT` metadata in the `metadata` mapping.
     *      5. Enqueue the token ID for ascension processing.
     *      6. Emit an `NFTMinted` event with the recipient, token ID, and per-NFT GPX stake.
     *  - After minting all NFTs, call `processAscensions(20)` to process up to 20 queued ascensions in this transaction.
     *
     * @param account The address receiving the newly minted NFTs.
     * @param batchSize The number of NFTs to mint in this batch. Must be > 0.
     * @param totalGPX The total amount of GPX to distribute evenly among all minted NFTs. Each NFT’s `gpxBalance` will be `totalGPX / batchSize`.
     * @return ids An array of all newly minted token IDs, in order of minting.
     */
    function mintBatch(
        address account,
        uint256 batchSize,
        uint256 totalGPX
    ) external onlyAuthorized returns (uint256[] memory ids) {
        // Ensure we have a valid Chainlink subscription ID
        if (subId == 0) {
            revert SubscriptionIdNotSet();
        }

        // Ensure at least one NFT is being minted
        if (batchSize == 0) {
            revert BatchSizeZero();
        }

        // Allocate the return array to hold each new token ID
        ids = new uint256[](batchSize);

        // Calculate how much GPX each NFT will stake
        uint256 gpxPerNFT = totalGPX / batchSize;

        for (uint256 i = 0; i < batchSize; i++) {
            // Generate a new unique token ID
            counter++;
            uint256 currentId = counter;

            // Build the initial metadata for this Miner NFT
            MiningNFT memory meta = MiningNFT({
                id: currentId,
                positionList: 0,        // Position in the level's player list, initialized to 0
                currentLevel: -1,       // -1 indicates the NFT is queued for initial ascension
                gpxBalance: gpxPerNFT   // GPX stake allocated to this NFT
            });

            // Mint the ERC-721 token to the buyer
            _safeMint(account, currentId);

            // Record the new token ID in the return array
            ids[i] = currentId;

            // Store the metadata in the on‐chain mapping
            metadata[currentId] = meta;

            // Enqueue this token for the ascension process
            prepareAscension(currentId);

            // Emit an event to signal that the NFT was minted
            emit NFTMinted(account, currentId, gpxPerNFT);
        }

        // Process the ascensions immediately with the new random numbers
        processAscensions(20);
    }

    /**
     * @notice Queue a newly minted Miner NFT for entry (ascension) into the mine.
     * @dev
     *  - Enqueues the NFT ID into the `tokensQueue` for later batch processing.
     *  - Simulates the number of VRF random words required to process all queued ascensions.
     *  - If additional VRF randomness is needed (`needsVRF == true`), triggers a VRF request.
     *
     * @param nftId The token ID of the Miner NFT to prepare for ascension.
     */
    function prepareAscension(uint256 nftId) internal {
        // Add the NFT ID to the queue for batch ascension processing
        tokensQueue.enqueue(nftId);

        // Determine whether more VRF words are needed to process the current queue
        ( , bool needsVRF, uint256 wordsRequired) = simulateTraverseLevels();

        // If simulation indicates more VRF words are required, request them now
        if (needsVRF) {
            requestVRF(wordsRequired);
        }
    }

    /// @notice Chainlink VRF configuration parameters
    bytes32 public keyHash; // Gas lane key hash identifying the specific VRF oracle/job
    uint256 public subId; // Subscription ID for funding VRF requests
    uint16 public requestConfirmations; // Number of block confirmations the VRF request will wait before fulfilling
    uint32 public callbackGasLimit; // Gas limit forwarded to the VRF callback function
    bool public nativePay; // If true, VRF requests are funded with native ETH; otherwise, LINK is used

    /**
     * @notice Updates the Chainlink VRF parameters used by this contract.
     * @dev Only the VRF Coordinator Owner may call this function. These parameters will apply to all subsequent VRF requests.
     *
     * @param _keyHash The gas lane key hash for selecting which VRF oracle to use.
     * @param _subId The Chainlink subscription ID that will be billed for VRF requests.
     * @param _requestConfirmations The number of block confirmations to wait before the VRF coordinator fulfills the request.
     * @param _callbackGasLimit The maximum amount of gas to forward to the VRF coordinator’s callback.
     * @param _nativePay If true, VRF requests will be funded with native ETH; if false, they will be funded with LINK.
     */
    function setVRFParameters(
        bytes32 _keyHash,
        uint256 _subId,
        uint16 _requestConfirmations,
        uint32 _callbackGasLimit,
        bool _nativePay
    ) external onlyVRFOwner {
        keyHash = _keyHash;
        subId = _subId;
        requestConfirmations = _requestConfirmations;
        callbackGasLimit = _callbackGasLimit;
        nativePay = _nativePay;
    }

    /**
     * @notice Requests random words from Chainlink VRF.
     * @dev 
     *  - Increments `vrfCounter` by the total number of words requested.  
     *  - Calls `requestRandomWords` on the VRF coordinator
     *  - Returns the `requestId` of the last VRF request made.  
     *
     * @param wordsRequired The total number of random words needed from Chainlink VRF.
     * @return requestId The VRF request ID for the final batch submitted.
     */
    function requestVRF(uint256 wordsRequired) internal returns (uint256 requestId) {
        // Track how many words are now outstanding
        vrfCounter += wordsRequired;

        // Send a VRF request for `batchSize` words
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: uint32(wordsRequired),
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({ nativePayment: nativePay }))
            })
        );
        
        emit VRFRequested(requestId, wordsRequired, vrfCounter);
    }

    /**
     * @notice Called by the Chainlink VRF coordinator with a batch of random words.
     * @dev 
     * - Enqueues each returned random word for later processing
     * - Decrements the internal `vrfCounter` by the number of words received. 
     * - The `requestId` is included to satisfy the VRF callback signature but is not used here.
     *
     * @param randomWords An array of random values provided by the Chainlink VRF coordinator.
     */
    function fulfillRandomWords(
        uint256, 
        uint256[] calldata randomWords
    ) internal override {
        // Loop through all returned randomWords...
        for (uint256 i = 0; i < randomWords.length; i++) {
            // ...and enqueue each one so it can be consumed by game logic later.
            randomNumbersQueue.enqueue(randomWords[i]);
        }
        // Decrement our counter of outstanding VRF words, since we've now received this batch.
        vrfCounter -= randomWords.length;

        emit VRFFulfilled(randomWords.length, vrfCounter);
    }

    /**
     * @notice Retrieves the current number of tokens awaiting processing in the queue.
     * @dev Calls the `length()` function on the `tokensQueue` to report how many NFTs are pending ascension.
     *
     * @return uint256 The total count of queued token IDs.
     */
    function tokensQueueLength() public view returns (uint256) {
        return tokensQueue.length();
    }

    /**
     * @notice Indicates whether there are pending tokens in the queue that require processing.
     * @dev Returns `true` if `tokensQueueLength()` is greater than zero, signaling that 'processAscensions' should be triggered.
     *
     * @return bool `true` if there are queued token IDs awaiting ascension; otherwise `false`.
     */
    function needsAutomation() external view returns (bool) {
        return tokensQueueLength() > 0;
    }

    /**
     * @notice Inserts GoldPesa Miners into the GoldPesa Mine and processes their ascension through levels.
     * @dev 
     * - Processes a batch of miners from the queue, limited by `maxIter` to avoid exceeding gas limits.
     * - Each miner's required number of random words is determined using `simulateTraverseLevels_words`.
     * - If enough random numbers are available, the miner is dequeued and either stays at level 0 or ascends.
     *
     * @param maxIter The maximum number of GoldPesa Miners to process in this call (to avoid block gas limit issues).
     */
    function processAscensions(uint256 maxIter) public {
        // Exit early if there are no miners to process
        if (tokensQueue.length() == 0)
            return;
        
        // Cap maxIter to the number of miners in the queue
        if (maxIter > tokensQueue.length() || maxIter == 0)
            maxIter = tokensQueue.length();

        // Loop through up to maxIter miners
        for(uint256 i = 0; i < maxIter; i++) {
            // Calculate how many random words are needed for a single miner
            uint256 words = simulateTraverseLevels_words(levelCounter, 1);

            // If not enough random numbers available, exit early
            if (words > randomNumbersQueue.length())
                break;

            // Dequeue the next miner
            uint256 currentId = tokensQueue.dequeue();
            metadata[currentId].currentLevel = 0;

            // Emit events for off-chain tracking
            emit Ascension(ownerOf(currentId), currentId, metadata[currentId].currentLevel);
            emit MetadataUpdate(currentId);

            // Place miner inside level 0
            levels[0].push(currentId);
            metadata[currentId].positionList = levels[0].length - 1;
            
            // If no words needed, just increment the level counter
            if (words == 0) {
                levelCounter++;
            }
            else {
                // Calculate how many levels the miner should ascend
                int8 _levels = int8(uint8(words));

                // Perform ascension through each level using a random index
                for(int8 lvl = 0; lvl < _levels; lvl++) {
                    ascend(lvl, randomNumbersQueue.dequeue() % levels[lvl].length);
                }

                // Adjust levelCounter depending on whether max level was reached
                if (_levels == MAX_LEVEL) {
                    levelCounter = 0x55555555 >> (32 - (words * 2));
                } else {
                    levelCounter += 1 + (0x55555555 >> (32 - (words * 2)));
                }
            }
        } 
    }

    /**
     * @notice Advances a winning GoldPesa Miner to the next level of the GoldPesa Mine.
     * @dev 
     * - This function is called when a miner is selected to ascend from the current level.
     * - It increments the miner’s level, removes them from their current level list, and appends them to the next level. 
     * - Events are emitted to reflect the change. 
     * - Players can only ascend if they are below the maximum level (MAX_LEVEL). 
     * - Once a miner reaches MAX_LEVEL-1, they remain on that level forever unless they choose to cash out and exit the mine.
     *
     * @param level The current level of the winning miner.
     * @param idx The index of the miner in the `levels[level]` array.
     */
    function ascend(
        int8 level, 
        uint256 idx
    ) internal {
        // Load the list of token IDs on the current level
        uint256[] storage tokensOnLevel = levels[level];

        // Get the token ID of the miner to ascend
        uint256 currToken = tokensOnLevel[idx];

        // Check if the miners next potential level is still below MAX_LEVEL
        if (level + 1 < MAX_LEVEL) {
            // Update and increment the current level of the miner
            metadata[currToken].currentLevel++;

            // Remove the miner from the current level's list
            _removeIndexFromLevel(level, idx);

            // Add the miner to the next level
            levels[level + 1].push(currToken);

            // Update the miner's new index position in the next level's list
            metadata[currToken].positionList = levels[level + 1].length - 1;

            // Emit events to notify external systems of the ascension and metadata change
            emit Ascension(ownerOf(currToken), currToken, level + 1);
            emit MetadataUpdate(currToken);
        }
    }

    /**
     * @notice Removes a token ID at the specified index from the given level.
     * @dev 
     * - This is an external wrapper around the internal _removeIndexFromLevel function.
     * - It allows authorized external callers to remove a token by index from a level's token list.
     * - The array is kept compact by swapping in the last token and popping the last element.
     *
     * @param level The level from which the token ID should be removed.
     * @param idx The index of the token ID to remove within the level's token list.
     * @return currToken The token ID that was removed from the level.
     */
    function removeIndexFromLevel(
        int8 level, 
        uint256 idx
    ) external onlyAuthorized returns (uint256 currToken) {
        return _removeIndexFromLevel(level, idx);
    }

    /**
     * @dev Removes a token ID at the specified index from a given level's token list.
     * - This function swaps the last element into the removed index and pops the last element.
     * 
     * @param level The level from which to remove the token.
     * @param idx The index of the token in the level's array to remove.
     * @return currToken The token ID that was removed.
     */
    function _removeIndexFromLevel(
        int8 level, 
        uint256 idx
    ) internal returns (uint256 currToken) {
        // Load the token list for the given level
        uint256[] storage tokensOnLevel = levels[level];
        uint256 len = tokensOnLevel.length;

        if (idx >= len) {
            revert IndexOutOfBounds(idx, len);
        }

        // Get the token to be removed
        currToken = tokensOnLevel[idx];

        // If it's not the last element, swap in the last one
        if (idx != len - 1) {
            uint256 lastToken = tokensOnLevel[len - 1];
            tokensOnLevel[idx] = lastToken;

            // Update the index of the moved token in metadata
            metadata[lastToken].positionList = idx;
        }

        // Remove the last element (either the moved one or the original if it was last)
        tokensOnLevel.pop();
    }

    /**
     * @notice Simulates the traversal of levels as if a GoldPesa Miner is entering the mine.
     * @dev 
     * - Determines how many random words are needed based on the current `levelCounter` 
     *   and the number of tokens in the queue.
     * 
     * @return totalWords The total number of random words required for the traversal.
     * @return needsVRF A boolean indicating whether additional VRF words are needed.
     * @return wordsRequired The number of additional VRF words needed (zero if not required).
     */
    function simulateTraverseLevels() internal view returns (
        uint256 totalWords, 
        bool needsVRF, 
        uint256 wordsRequired
    ) {
        totalWords = simulateTraverseLevels_words(levelCounter, tokensQueue.length()) - randomNumbersQueue.length();
        needsVRF = totalWords > vrfCounter;
        if (needsVRF) wordsRequired = totalWords - vrfCounter;
    }

    /// @notice deBruijnBitPosition
    uint32[32] deBruijnBitPosition = 
            [uint32(0), 1, 28, 2, 29, 14, 24, 3, 30, 22, 20, 15, 25, 17, 4, 8, 
            31, 27, 13, 23, 21, 19, 16, 7, 26, 12, 18, 6, 11, 5, 10, 9];
    
    /**
     * @notice Simulates how many random words are required for a set of miners to traverse the mine.
     * @dev 
     * - This function simulates `_n` miners entering the mine, incrementing a virtual `levelCounter`
     *   and computing how many "words" (units of randomness) would be needed if those miners ascended.
     * - It uses a De Bruijn sequence to efficiently determine the position of the least significant set bit
     *   in the counter, which represents the level depth.
     *
     * @param _counter The current virtual level counter used to simulate entry state.
     * @param _n The number of miners to simulate.
     * @return totalWords The total number of random words needed for the simulated miners.
     */
    function simulateTraverseLevels_words(
        uint256 _counter, 
        uint256 _n
    ) internal view returns (uint256 totalWords) {
        uint32 _maxLevel = uint32(uint8(MAX_LEVEL));
        for(uint256 n = 0; n < _n; n++) {
            _counter++;

            uint32 _levels = deBruijnBitPosition[(((_counter & (~_counter + 1)) * 0x077CB531) >> 27) & 31];
            _levels -= _levels % 2;
            if (_levels / 2 == _maxLevel)
                _counter = 0x55555555 >> (32 - _levels);
            else if (_levels > 0)
                _counter |= 0x55555555 >> (32 - _levels);
            totalWords += _levels / 2;
        }
    }

    /**
     * @notice Grants approval to the GPMTreasury contract to burn the specified token.
     * @dev 
     * - This function allows an authorized caller to approve the GPMTreasury (`gpmt`) to manage (e.g., burn) the given `tokenId`. 
     *
     * @param tokenId The ID of the token to approve for the GPMTreasury.
     * @param auth The address initiating the approval (typically the token owner).
     */
    function unsafeApprove(
        uint256 tokenId, 
        address auth
    ) external onlyAuthorized {
        _approve(address(gpmt), tokenId, auth);
    }

    /**
     * @dev Indicates whether the contract implements a given interface.
     * Required to resolve ambiguity between ERC721 and ERC721Enumerable.
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Increases the balance of an account.
     * Overrides to resolve multiple inheritance from ERC721 and ERC721Enumerable.
     */
    function _increaseBalance(
        address account, 
        uint128 amount
    ) internal virtual override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, amount);
    }

    /**
     * @dev Updates token ownership and related state.
     * Overrides to resolve ambiguity between ERC721 and ERC721Enumerable implementations.
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override(ERC721, ERC721Enumerable) returns (address) {
        // Use super to call the parent implementations if necessary
        return super._update(to, tokenId, auth);
    }
}