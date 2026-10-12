// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { GoldPesaMines } from "./GoldPesaMines.sol";
import { GPX } from "../gpx/GPX.sol";
import { IERC20Permit } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { IV4Quoter } from "v4-periphery/src/interfaces/IV4Quoter.sol";
import { IV4Router } from "v4-periphery/src/interfaces/IV4Router.sol";
import { IUniversalRouter } from "../utils/IUniversalRouter.sol";
import { Commands } from "../utils/Commands.sol";
import { Actions } from "v4-periphery/src/libraries/Actions.sol";
import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { GPXOwner } from "../gpxowner/GPXOwner.sol";
import { IWETH } from "../utils/IWETH.sol";
import { IStateView } from "v4-periphery/src/interfaces/IStateView.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GoldPesa Mines Treasury (GPMT)
 * @notice This contract handles the financial logic for the GoldPesa Mine, including NFT purchases, token swaps, and prize redemptions. 
 * - It serves as the economic backbone of the system, enabling users to buy GoldPesa Miner NFTs using USDC/ETH and other ERC20 tokens 
 *   or by staking GPX, and later cash out their rewards in GPX.
 *
 * Core Responsibilities:
 * - Facilitates the purchase of GoldPesa Miner NFTs
 * - Enables direct staking of GPX to mint NFTs.
 * - Manages token approvals via Permit2 for gas-efficient interactions.
 * - Handles the redemption (cash-out) of GPX rewards by NFT holders based on their level in the mine.
 * - Interfaces with Uniswap router infrastructure for pricing and execution.
 * - Ensures NFTs are burned upon exit and rewards are transferred securely.
 *
 * Important Constants:
 * - `NFT_PRICE_IN_USDC`: Fixed price of $10 USDC per NFT.
 * - `NFT_FEE_IN_USDC`: Fixed fee of $1 USDC per NFT.
 *
 * Emits:
 * - `NFTPurchased`: When a user successfully purchases one or more NFTs.
 * - `Cashout`: When a user redeems their GPX and exits the mine.
 */
contract GPMTreasury is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    // =======================
    // ======= ERRORS ========
    // =======================

    /// @notice Thrown when the provided tokenIn address is invalid (e.g., zero address).
    error InvalidTokenIn(address tokenIn);
    /// @notice Thrown when buying NFT and the recipient address is zero.
    error RecipientZero();
    /// @notice Thrown when buying NFT and the purchase quantity is zero.
    error QuantityOutOfRange();
    /// @notice Thrown when the provided maximum GPX amount is less than the required amount.
    error InsufficientGPX(uint256 amountInMaximum, uint256 amountIn);
    /// @notice Thrown when the provided maximum USDC amount is less than the required amount.
    error InsufficientUSDC(uint256 amountInMaximum, uint256 amountIn);
    /// @notice Thrown when the USDC balance inside the mine is insufficient to cover the required amount.
    error InsufficientUSDCInsideMine(uint256 balance, uint256 usdcTotal);
    /// @notice Thrown when user is not the owner during cashout
    error NotTokenOwner(address have, address want);

    // =======================
    // ======= EVENTS ========
    // =======================

    /// @notice Emitted when a user purchases GoldPesa Miner NFTs
    /// @param buyer The address that initiated the purchase
    /// @param account The address that received the newly minted NFTs
    /// @param tokenIn The token address used for payment (could be GPX, USDC, WETH, or another ERC-20)
    /// @param amountIn The amount of `tokenIn` actually spent 
    /// @param quantity The number of NFTs purchased
    /// @param gpxStaked The net amount of GPX used for staking
    event NFTPurchased(
        address indexed buyer,
        address indexed account,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 quantity,
        uint256 gpxStaked
    );

    /// @notice Emitted when a GoldPesa Miner NFT is cashed out by its owner
    /// @param account The address of the user cashing out
    /// @param token The ID of the NFT being redeemed
    /// @param atLevel The level the NFT had reached before exiting the mine
    /// @param gpxOut The total amount of GPX transferred to the user
    event Cashout(
        address indexed account, 
        uint256 indexed token, 
        int8 atLevel, 
        uint256 gpxOut
    );

    // =================================
    // ========== CONSTANTS ============
    // =================================

    /// @notice GoldPesa Miner NFT fixed price = $10 USDC (6 decimals)
    uint256 public constant NFT_PRICE_IN_USDC = 10e6;
    /// @notice GoldPesa Miner NFT fixed fee = $1 USDC (6 decimals)
    uint256 public constant NFT_FEE_IN_USDC = 1e6;
    /// @notice Wrapped ETH address on the Base chain
    address public constant WETH_ADDRESS = address(0x4200000000000000000000000000000000000006);

    // =================================
    // ======= PUBLIC STATE GETTERS ====
    // =================================

    /// @notice GPX token 
    IERC20 public immutable gpx;
    /// @notice USDC token
    IERC20 public immutable usdc;
    /// @notice GoldPesa Mines contract
    GoldPesaMines public immutable gpMines;
    /// @notice GPX Uniswap V4 PoolKey 
    PoolKey public gpxPoolKey;
    /// @notice Uniswap V4 Quoter
    IV4Quoter public immutable quoter;
    /// @notice Uniswap V4 Universal Router
    IUniversalRouter public immutable router; 
    /// @notice Permit2 
    IPermit2 public immutable permit2;
    /// @notice GPXOwner 
    GPXOwner public immutable gpxOwner;
    /// @notice Uniswap V4 State View
    IStateView public immutable stateview;

    /// @notice Total amount of GPX staked in the contract
    uint256 public totalGPXStaked;

    // =================================
    // ==== PRIVATE STATE VARIABLES ====
    // =================================

    /// @dev No Hook Data
    bytes private constant ZERO_BYTES = bytes("");

    // ============================
    // ======== CONSTRUCTOR =======
    // ============================

    /**
     * @dev Initializes the GoldPesa Mines Treasury (GPMT) contract.
     *
     * @param _gpx GPX token address
     * @param _usdc USDC token address
     * @param _gpMines GoldPesa Mines address
     * @param _quoter Uniswap V4 Quoter address
     * @param _gpxPoolKey GPX/USDC Uniswap V4 PoolKey
     * @param _router Uniswap V4 Universal Router address
     * @param _permit2 Permit2 address for approvals
     * @param _gpxOwner GPXOwner contract
     * @param _stateview Uniswap V4 State View address
     */
    constructor(
        address _gpx, 
        address _usdc,
        address _gpMines,
        address _quoter,
        PoolKey memory _gpxPoolKey,
        address _router,
        address _permit2,
        GPXOwner _gpxOwner,
        address _stateview
    ) {
        require(_gpx != address(0) && _usdc != address(0) && _gpMines != address(0) && 
            _quoter != address(0) && _router != address(0) && _permit2 != address(0) && 
            _stateview != address(0), "Invalid contract address");
        
        gpx = IERC20(_gpx);
        usdc = IERC20(_usdc);
        gpMines = GoldPesaMines(_gpMines);
        quoter = IV4Quoter(_quoter);
        gpxPoolKey = _gpxPoolKey;
        router = IUniversalRouter(_router);
        permit2 = IPermit2(_permit2);
        gpxOwner = _gpxOwner;
        stateview = IStateView(_stateview);
    }

    // ============================
    // ======= MAIN FUNCTION ======
    // ============================

    /**
     * @notice Calculates the total net earnings held by the mine contract in GPX and USDC
     * @dev This includes only net GPX earnings inside the mine contract excluding staked GPX
     * @return totalMineEarningsInGPX The total earnings inside the mine.
     * @return totalMineEarningsInUSDC The total USDC-equivalent value (6 decimals) of the GPX earnings held by the mine.
     */
    function getTotalMineEarnings() public view returns (uint256 totalMineEarningsInGPX, uint256 totalMineEarningsInUSDC) {
        // Total GPX tokens currently held by the mine contract exclusive of staked GPX
        totalMineEarningsInGPX = gpx.balanceOf(address(this)) - totalGPXStaked;

        // Convert to its USDC value
        totalMineEarningsInUSDC = getGPXValueInUSDC(totalMineEarningsInGPX);
    }

    /**
     * @notice Calculates the total value of all GPX tokens held by the mine contract in GPX and USDC
     * @dev This includes all GPX staked and GPX earnings inside the mine contract.
     * @return totalMineValueInGPX The total GPX inside the mine.
     * @return totalMineValueInUSDC The total USDC-equivalent value (6 decimals) of the GPX held by the mine.
     */
    function getTotalMineValue() public view returns (uint256 totalMineValueInGPX, uint256 totalMineValueInUSDC) {
        // Total GPX tokens currently held by the mine contract
        totalMineValueInGPX = gpx.balanceOf(address(this));

        // Convert the total GPX amount to its USDC value
        totalMineValueInUSDC = getGPXValueInUSDC(totalMineValueInGPX);
    }

    /**
     * @notice Calculates the total USDC-equivalent value of a specific NFT's GPX holdings.
     * @dev The total GPX includes staked GPX and any unclaimed prize GPX.
     * @param tokenId The ID of the GoldPesa Miner NFT.
     * @return totalNFTValueInUSDC The USDC-equivalent value (6 decimals) of the NFT’s GPX balance.
     */
    function getTotalNFTValueInUSDC(uint256 tokenId) public view returns (uint256 totalNFTValueInUSDC) {
        // Fetch the total GPX associated with this NFT
        uint256 gpxAmount = gpMines.getTotalGPXBalance(tokenId);

        // Convert it to USDC equivalent
        totalNFTValueInUSDC = getGPXValueInUSDC(gpxAmount);
    }

    /**
     * @notice Converts any given GPX token amount to its USDC-equivalent value using the Uniswap V4 pool price.
     * @param gpxAmount The GPX amount to convert (18 deciamls).
     * @return usdcValue The USDC-equivalent value (6 decimals).
     */
    function getGPXValueInUSDC(uint256 gpxAmount) public view returns (uint256 usdcValue) {
        // Fetch sqrtPriceQ96 from Uniswap V4 pool
        (uint160 sqrtPriceQ96, , , ) = stateview.getSlot0(gpxPoolKey.toId());

        // Convert sqrtPriceQ96 to PriceQ96
        uint256 priceQ96 = FullMath.mulDiv(uint256(sqrtPriceQ96), uint256(sqrtPriceQ96), 1 << 96);

        // Calculate USDC value of the given GPX amount
        usdcValue = FullMath.mulDiv(priceQ96, gpxAmount, 1 << 96);

    }

    /**
     * @notice Buy GoldPesa Miner NFT using a token which supports IERC20Permit (ERC-2612)
     * 
     * @param amountInMaximum: Maximum amount of tokenIn for purchasing NFT
     * @param tokenIn: Token In Address 
     * @param poolFee The Uniswap V3 pool fee tier (e.g., 3000 for 0.3%) when swapping from `tokenIn` → USDC (if needed).
     * @param deadline: Time allocated for transaction before reverting
     * @param account: Address of wallet receiving NFTs
     * @param quantity: Number of NFT's to purchase
     * @param v: Signature value
     * @param r: Signature value
     * @param s: Signature value
     *
     * @return amountIn The actual amount of `tokenIn` consumed by this transaction (before any refund).
     * @return gpxStaked The net amount of GPX used to stake (after subtracting any bonus or fee).
     * @return ids An array of newly minted NFT IDs.
     */
    function buyNFTSig(
        uint256 amountInMaximum, 
        address tokenIn, 
        uint24 poolFee,
        uint256 deadline, 
        address account, 
        uint256 quantity,
        uint8 v, 
        bytes32 r, 
        bytes32 s
    ) external nonReentrant returns (uint256 amountIn, uint256 gpxStaked, uint256[] memory ids) {
        if (tokenIn == address(0)) {
            revert InvalidTokenIn(tokenIn);
        }

        // If no deadline provided, default to 5 minutes out
        if (deadline == 0) {
            deadline = block.timestamp + 300;
        }

        IERC20Permit(tokenIn).permit(msg.sender, address(this), amountInMaximum, deadline, v, r, s);

        (amountIn, gpxStaked, ids) = _buyNFT(amountInMaximum, tokenIn, poolFee, deadline, account, quantity);
    }

    /**
     * @notice Purchase GoldPesa Miner NFTs using any supported token or native ETH.
     *
     * @dev
     *  - If `tokenIn` is address(0), the function treats `msg.value` as ETH, wraps it into WETH, and uses that as `tokenIn`.
     *  - If `tokenIn` is GPX, we directly calculate the GPX amount required (including a 10% fee in GPX),
     *    transfer that amount from the buyer, send the fee portion to the fee receipient, and mint NFTs using the remaining GPX.
     *  - If `tokenIn` is USDC, we transfer the required USDC (price + fee) from the buyer, send the fee portion to the fee receipient, 
     *    swap the price portion to GPX, and mint NFTs.
     *  - For all other ERC-20 tokens, we pull up to `amountInMaximum` of `tokenIn` from the buyer, swap exactly the USDC total (price + fee) 
     *    out of `tokenIn` via Uniswap V3 (exact-out), refund any unused `tokenIn` to the buyer (unwrapping WETH back to ETH if necessary), 
     *    send the USDC fee, swap the USDC price portion into GPX, send a small “lucky” GPX amount to the buyer, 
     *    and then mint NFTs with the remaining GPX stake.
     *
     *  - The function enforces that `quantity > 0` and `account` is nonzero.
     *  - A `deadline` of zero will be replaced with `block.timestamp + 300` seconds.
     *  - All transfers, approvals, and swaps occur before any NFTs are minted.
     *
     * @param amountInMaximum The maximum amount of `tokenIn` (or wrapped native ETH) the buyer is willing to spend.
     * @param tokenIn The input token’s address. Use `address(0)` to pay in native ETH (wrapped internally to WETH).
     * @param poolFee The Uniswap V3 pool fee tier (e.g., 3000 for 0.3%) when swapping from `tokenIn` → USDC (if needed).
     * @param deadline The Unix timestamp by which all on-chain operations (especially swaps) must complete.
     *                 If set to 0, it defaults to `block.timestamp + 300`.
     * @param account The recipient address that will receive the newly minted NFTs.
     * @param quantity How many GoldPesa Miner NFTs to purchase.
     *
     * @return amountIn The actual amount of `tokenIn` (or WETH/ETH) consumed by this transaction
     * @return gpxStaked The net amount of GPX used to stake (after subtracting any “lucky” amount or fee).
     * @return ids An array of NFT IDs that were minted for the buyer.
     */
    function buyNFT(
        uint256 amountInMaximum,
        address tokenIn,
        uint24 poolFee,
        uint256 deadline,
        address account,
        uint256 quantity
    ) external payable nonReentrant returns (uint256 amountIn, uint256 gpxStaked, uint256[] memory ids) {
        // Call internal logic for NFT purchase
        (amountIn, gpxStaked, ids) = _buyNFT(amountInMaximum, tokenIn, poolFee, deadline, account, quantity);
    }

    /// @dev Internal logic for NFT purchase. See `buyNFT` for full description.
    function _buyNFT(
        uint256 amountInMaximum,
        address tokenIn,
        uint24 poolFee,
        uint256 deadline,
        address account,
        uint256 quantity
    ) internal returns (uint256 amountIn, uint256 gpxStaked, uint256[] memory ids) {
        // Recipient cannot be zero
        if (account == address(0)) {
            revert RecipientZero();
        }

        // Quantity must be greater than zero and less than 100
        if (quantity == 0 || quantity > 100) {
            revert QuantityOutOfRange();
        }

        // If no deadline provided, default to 5 minutes out
        if (deadline == 0) {
            deadline = block.timestamp + 300;
        }

        // If paying with ETH (tokenIn == address(0)), wrap into WETH
        if (tokenIn == address(0)) {
            amountInMaximum = msg.value;
            tokenIn = WETH_ADDRESS;
            IWETH(tokenIn).deposit{value: msg.value}();
        }

        // Calculate total USDC needed: price + fee
        uint256 usdcPrice = NFT_PRICE_IN_USDC * quantity;
        uint256 usdcFee   = NFT_FEE_IN_USDC  * quantity;
        uint256 usdcTotal = usdcPrice + usdcFee;

        // Case A: Buyer is paying directly in GPX
        if (tokenIn == address(gpx)) {
            // Determine required GPX amount (including 10% fee)
            amountIn = getQuote(quantity);

            // Ensure buyer has enough GPX to cover the purchase
            if (amountInMaximum < amountIn) {
                revert InsufficientGPX(amountInMaximum, amountIn);
            }

            // Transfer GPX from buyer to this contract
            gpx.safeTransferFrom(msg.sender, address(this), amountIn);

            // Split GPX into fee (10%) and price (90%)
            gpxStaked = (amountIn * 100) / 110; 
            uint256 gpxFee = amountIn - gpxStaked; 

            // Send fee portion to fee recipient
            gpx.safeTransfer(gpxOwner.owner(), gpxFee);

            // Update total GPX staked in the contract
            totalGPXStaked += gpxStaked;

            // Mint NFTs using the remaining GPX stake
            ids = gpMines.mintBatch(account, quantity, gpxStaked);

            // Emit event
            emit NFTPurchased(msg.sender, account, tokenIn, amountIn, quantity, gpxStaked);

            return (amountIn, gpxStaked, ids);
        } 
        else {
            // Case B: Buyer is paying in USDC
            if (tokenIn == address(usdc)) {
                // Ensure buyer has allowed enough USDC to cover the purchase
                if (amountInMaximum < usdcTotal) {
                    revert InsufficientUSDC(amountInMaximum, usdcTotal);
                }

                // Set return amountIn to the total USDC amount
                amountIn = usdcTotal;

                // Transfer USDC from buyer to this contract
                usdc.safeTransferFrom(msg.sender, address(this), usdcTotal);
            }
            // Case C: Buyer is paying in any other ERC-20 (or WETH if wrapped)
            else {
                // Pull up to amountInMaximum from buyer (unless it’s already WETH from above)
                if (tokenIn != WETH_ADDRESS) {
                    IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountInMaximum);
                }

                // Approve Permit2 so the Universal Router can pull tokens
                approveTokenWithPermit2(
                    tokenIn,
                    amountInMaximum,
                    uint48(block.timestamp + 300)
                );

                // Record balance before swap
                uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));

                // Swap EXACT‐OUT: spend up to `amountInMaximum` of tokenIn to receive `usdcTotal` USDC
                swapExactOutV3Single(
                    address(this),            // contract itself as recipient
                    usdcTotal,                // desired EXACT amount of USDC
                    amountInMaximum,          // max tokenIn to spend
                    tokenIn,                  // input token
                    address(usdc),            // output token
                    poolFee
                );

                // Figure out how much tokenIn was actually spent
                uint256 balanceAfter = IERC20(tokenIn).balanceOf(address(this));

                // Set return amountIn to the difference in balance
                amountIn = balanceBefore - balanceAfter;

                // Refund any unused tokenIn
                uint256 refund = amountInMaximum - amountIn;
                
                if (refund > 0) {
                    if (tokenIn == WETH_ADDRESS) {
                        // If wrapped ETH (WETH), unwrap and refund as ETH
                        IWETH(tokenIn).withdraw(refund);
                        payable(msg.sender).transfer(refund);
                    } else {
                        // Otherwise, transfer leftover ERC20 back
                        IERC20(tokenIn).transfer(msg.sender, refund);
                    }
                }
            }

            // At this point, we have `usdcTotal` USDC in this contract
            uint256 usdcBalance = usdc.balanceOf(address(this));
            if (usdcBalance < usdcTotal) {
                revert InsufficientUSDCInsideMine(usdcBalance, usdcTotal);
            }

            // Send the USDC fee portion to the fee recipient
            usdc.safeTransfer(gpxOwner.owner(), usdcFee);

            // Approve Permit2 for the router to pay exactly `usdcPrice` USDC
            approveTokenWithPermit2(
                address(usdc),
                usdcPrice.toUint160(),
                uint48(block.timestamp + 300)
            );

            // Calculate the GPX balance before swap 
            uint256 gpxBalanceBeforeSwap = gpx.balanceOf(address(this));

            // Swap `usdcPrice` USDC → GPX using the Universal Router
            swapExactInputSingle(
                gpxPoolKey,
                usdcPrice.toUint128(),
                uint128(0), 
                false
            );

            // Calculate the GPX balance after swap
            uint256 gpxBalanceAfterSwap = gpx.balanceOf(address(this));

            // Calculate the amount of GPX received from the swap
            uint256 gpxAmountOut = gpxBalanceAfterSwap - gpxBalanceBeforeSwap;

            // Calculate and transfer lucky amount to receipient (0.01%)
            uint256 luckyAmount = gpxAmountOut / 10_000;
            gpx.transfer(account, luckyAmount);

            // Remaining GPX after lucky transfer
            gpxStaked = gpxAmountOut - luckyAmount; 

            // Mint NFTs using the remaining GPX stake after lucky transfer
            ids = gpMines.mintBatch(account, quantity, gpxStaked);

            // Update total GPX staked in the contract
            totalGPXStaked += gpxStaked;

            // Emit purchase event
            emit NFTPurchased(msg.sender, account, tokenIn, amountIn, quantity, gpxStaked);

            return (amountIn, gpxStaked, ids);
        }
    }

    /**
     * @notice Cash out all accumulated GPX rewards for a specific GoldPesa Miner NFT and remove it from the mine.
     * @dev
     *  - Ensures the caller owns the NFT.
     *  - Approves the caller to burn the NFT in the GoldPesaMines contract.
     *  - Retrieves the NFT’s current level and stored GPX balance.
     *  - Computes total GPX due (level-based prize + stored balance).
     *  - Transfers GPX to the NFT owner, removes the NFT from its level queue and burns it.
     *  - Emits a `Cashout` event with details of the payout.
     *
     * @param tokenId The ID of the GoldPesa Miner NFT to cash out.
     */
    function cashOut(uint256 tokenId) external nonReentrant {
        // Verify that the caller is the current owner of the NFT
        address owner = gpMines.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert NotTokenOwner(msg.sender, owner);
        }

        // Grant approval for this contract to burn the NFT on behalf of the owner
        gpMines.unsafeApprove(tokenId, msg.sender);

        // Retrieve the NFT’s stored metadata: (id, positionInLevel, currentLevel, storedGPXBalance)
        (, uint256 positionList, int8 currentLevel, uint256 gpxBalance) = gpMines.metadata(tokenId);

        // Calculate total GPX due:
        // 1) The earnings based on the miner’s current level
        // 2) NFT's original GPX Stake balance
        uint256 gpxEarnings = gpMines.gpxTotalPrizeAt(currentLevel);
        uint256 gpxDue = gpxEarnings + gpxBalance;

        // Transfer the total GPX due to the NFT owner
        gpx.transfer(owner, gpxDue);

        // Update the total GPX staked in the contract
        totalGPXStaked -= gpxBalance;

        // Remove NFT from its current level’s queue
        gpMines.removeIndexFromLevel(currentLevel, positionList);

        // Burn the NFT to complete the cash-out and exit from the mine
        gpMines.burn(tokenId);

        // Emit an event for off-chain indexing
        emit Cashout(msg.sender, tokenId, currentLevel, gpxDue);
    }

    /**
     * @notice Returns a quote for the amount of GPX required to purchase a given number of GoldPesa Miner NFTs.
     *         This quote includes both the base price and the additional fee per NFT, calculated in USDC and 
     *         converted to GPX using the current Uniswap V4 pool price.
     *
     * @dev Uses the Uniswap V4 Quoter to simulate a USDC → GPX swap, estimating how much GPX would be 
     *      required to acquire the specified quantity of NFTs. The function assumes the NFT is priced in USDC and determines the GPX equivalent.
     *
     * @param quantity Number of NFTs to purchase.
     *
     * @return gpxAmount Estimated amount of GPX required to cover both price and fee for the NFTs.
     */
    function getQuote(uint256 quantity) public returns (uint256 gpxAmount) {
        // Total price in USDC for the NFTs
        uint256 usdcPrice = NFT_PRICE_IN_USDC * quantity;
        // Total fee in USDC for the NFTs
        uint256 usdcFee = NFT_FEE_IN_USDC * quantity;
        // Calculate the total amount of USDC needed
        uint256 usdcTotal = usdcPrice + usdcFee;

        // Prepare the quote parameters for the Uniswap V4 Quoter
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: gpxPoolKey,
            zeroForOne: false,
            exactAmount: usdcTotal.toUint128(),
            hookData: bytes("")
        });

        (gpxAmount, ) = quoter.quoteExactInputSingle(params);
    }

    /**
     * @notice Approves a token for Permit2 and authorizes the router to spend a specified amount.
     * @dev 
     * - Sets the ERC20 allowance for the Permit2 contract to the max uint256 value.
     * - Registers the Permit2 approval for the Universal Router to spend a specific amount until expiration.
     *
     * @param token The address of the ERC20 token to approve.
     * @param amount The specific amount to approve via Permit2 (uint160 max).
     * @param expiration The timestamp at which the Permit2 approval expires.
     */
    function approveTokenWithPermit2(
        address token,
        uint256 amount,
        uint48 expiration
    ) internal {
        address spender = address(router); // Universal Router is the spender
    
        // Grant standard ERC20 approval to Permit2 with unlimited allowance
        if (IERC20(token).allowance(address(this), address(permit2)) < amount) {
            IERC20(token).approve(address(permit2), 0);
            IERC20(token).approve(address(permit2), type(uint256).max);
        }

        // Register Permit2 approval to allow the router to spend the specified amount
        permit2.approve(
            token,
            spender,
            amount.toUint160(), // Permit2 uses uint160 for amount
            expiration          // Permit2 uses uint48 for expiration
        );
    }

    /**
     * @notice Executes a swap of a known input amount for a minimum output amount via the Uniswap V4 Universal Router.
     * @dev 
     * - Encodes the V4 Universal Router command to perform an exact input single swap.
     * - Handles token direction via `zeroForOne` flag.
     * - Performs the swap, settles funds, and takes all outputs.
     *
     * @param key The PoolKey identifying the Uniswap V4 pool (includes tokens, fee, etc.)
     * @param amountIn Exact amount of input token to swap.
     * @param minAmountOut Minimum acceptable amount of output token (used for slippage control).
     * @param zeroForOne Swap direction: true = token0 → token1, false = token1 → token0.
     */
    function swapExactInputSingle(
        PoolKey memory key,
        uint128 amountIn,
        uint128 minAmountOut,
        bool zeroForOne
    ) internal {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("")
            })
        );

        if (zeroForOne) {
            params[1] = abi.encode(key.currency0, amountIn);
            params[2] = abi.encode(key.currency1, minAmountOut);
        }
        else {
            params[1] = abi.encode(key.currency1, amountIn);
            params[2] = abi.encode(key.currency0, minAmountOut);
        }
       
        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        router.execute(commands, inputs, block.timestamp + 300);
    }

    /**
     * @notice Swap exactly `amountOut` of `tokenOut`, paying up to `amountInMax` of `tokenIn`, via Uniswap V3 “exact‐out” through the Universal Router.
     *
     * @param recipient   The address that should receive the exact‐out `amountOut` of `tokenOut`.
     * @param amountOut   The exact amount of `tokenOut` you want to receive.
     * @param amountInMax The maximum amount of `tokenIn` you’re willing to spend.
     * @param tokenIn     The address of the token you are selling.
     * @param tokenOut    The address of the token you want to buy.
     * @param poolFee     The Uniswap V3 pool fee (e.g. 500, 3000, 10000) to use for this single‐hop swap.
     */
    function swapExactOutV3Single(
        address recipient,
        uint256 amountOut,
        uint256 amountInMax,
        address tokenIn,
        address tokenOut,
        uint24 poolFee
    ) internal {
        // 1) Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V3_SWAP_EXACT_OUT));
        bytes[] memory inputs = new bytes[](1);

        // 2) Pack (tokenIn | fee | tokenOut) into a single bytes “path”:
        bytes memory path = abi.encodePacked(
            tokenOut,               // 20 bytes
            poolFee,                // 3 bytes (uint24)
            tokenIn                 // 20 bytes                                       
        );
       
        // 3) Build the inputs array. For V3_SWAP_EXACT_OUT, the encoding is:
        //    (address recipient, uint256 amountOut, uint256 amountInMax, bytes path, bool payerIsUser)
        inputs[0] = abi.encode(
            recipient,        // who receives the output tokens
            amountOut,        // EXACT amount of tokenOut you want
            amountInMax,      // max you are willing to spend of tokenIn
            path,             // packed [tokenIn | fee | tokenOut]
            true              // payerIsUser = true because the contract is paying
        );

        // 4) Finally, call the Universal Router with a deadline (e.g. block.timestamp + 300):
        router.execute(commands, inputs, block.timestamp + 300);
    }

    // ============================
    // ======= ETH GUARD ==========
    // ============================
    
    /**
     * @dev Fallback function to accept ETH
     */
    receive() external payable {}

    /**
     * @dev Fallback function accept ETH with data
     */
    fallback() external payable {}
}