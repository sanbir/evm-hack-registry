// SPDX-License-Identifier: MIT
// Liquidity Controller. Deals with all TraderJoe liquidity functions.
pragma solidity ^0.8.10;

// import {ERC20} from "solmate/tokens/ERC20.sol";
// import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {PriceHelper} from "joe-v2/libraries/PriceHelper.sol";

// import {IUniswapV2Pair} from "uni-v2/interfaces/IUniswapV2Pair.sol";
// import {IUniswapV3Pool} from "uni-v3/interfaces/IUniswapV3Pool.sol";

import {ILBRouter} from "joe-v2/interfaces/ILBRouter.sol";
import {LBRouter} from "joe-v2/LBRouter.sol";
import {LBPair} from "joe-v2/LBPair.sol";
import {ILBToken} from "joe-v2/interfaces/ILBToken.sol";

import {UltraJimbo} from "./UltraJimbo.sol";
import {Jimbo} from "./Jimbo.sol";

// primary liquidity operator for traderJoe pools
contract JimboController {
    using PriceHelper for uint256;

    event Borrow(address indexed user, uint256 ethAmount, uint256 jimboAmount);

    // error CannotShift();
    // error CannotReset();
    // error CannotRecycle();
    error AlreadyBorrowed();
    error NoActiveBorrows();
    error HardResetNotEnabled();
    error NotEnoughEthToBorrow();

    event Rebalance(bool didShift_, bool didReset_, bool didRecycle_);
    event BinsSet(
        uint24 floorBin_,
        uint24 anchorBin_,
        uint24 triggerBin_,
        uint24 maxBin
    );

    // Tokens and internal contract dependencies

    IERC20 public constant weth =
        IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1); // WETH

    Jimbo public immutable jimbo;
    UltraJimbo public immutable uJimbo;

    // External contract dependencies

    LBRouter public constant router =
        LBRouter(payable(0xb4315e873dBcf96Ffd0acd8EA43f689D8c20fB30));
    LBPair public immutable pair;

    // Utility Constants

    uint256 public constant PRECISION = 1e18;

    // Setup variables

    address public immutable jrs; // fee collection address
    uint24 public constant INITIAL_BIN_ID = 8387672; // SET at 0.00009074297398 ETH = .16337c
    uint16 public constant BIN_STEPS = 100; // bin steps for the pair

    // Liquidity rebalance state

    uint24 public constant NUM_ANCHOR_BINS = 5;
    uint24 public constant NUM_LIQ_BINS = 51;

    uint24 public floorBin; // floor bin where liq sits
    uint24 public anchorBin; // bin before floor bin
    uint24 public triggerBin; // recorded bin to know where rebalances occur.
    uint24 public maxBin; // this is the last bin where we have liq

    // Lending state

    uint256 public totalBorrowedEth; // total ETH taken out of the floor bin that is owed to the protocol
    mapping(address => uint256) public borrowedEth; // ETH owed to the protocol by each user
    mapping(address => uint256) public uJimboDeposited; // uJimbo deposited by each user

    bool public hardResetEnabled;

    constructor(address jrs_) {
        // Set the proper addresses
        jrs = jrs_;

        // Deploy Jimbo ERC20 and UltraJimbo ERC4626
        jimbo = new Jimbo(jrs);
        uJimbo = new UltraJimbo(address(jimbo));
        jimbo.setVault(address(uJimbo));

        // Create the JIMBO TJ pool
        pair = LBPair(
            address(
                router.createLBPair(
                    IERC20(address(jimbo)),
                    weth,
                    INITIAL_BIN_ID,
                    BIN_STEPS
                )
            )
        );

        // Max approve tokens for the TJ pool
        jimbo.approve(address(router), type(uint256).max);
        jimbo.approve(address(uJimbo), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        ILBToken(address(pair)).approveForAll(address(router), true);
        ILBToken(address(pair)).approveForAll(address(pair), true);

        // Deposit first vault share
        jimbo.setIsRebalancing(true);
        uJimbo.deposit(1e18, address(0));

        // Deploy JIMBO liquidity to the TJ pool
        _deployJimboLiquidity();
        jimbo.setIsRebalancing(false);

        // initial bin state
        uint24 activeBin = pair.getActiveId();
        _setBinState({
            floorBin_: activeBin,
            anchorBin_: activeBin,
            triggerBin_: activeBin + NUM_ANCHOR_BINS,
            maxBin_: activeBin + NUM_LIQ_BINS - 1 // include of active bin so -1
        });
    }

    /// -----------------------------------------------------------------------
    /// BORROWING — These are commented because they may change how we calculate floor bin
    /// -----------------------------------------------------------------------

    /// @notice Calculate max borrowable ETH based on uJIMBO balance
    /// @dev    Allows any input amount of uJIMBO, even if higher than total supply.
    ///         Must be gated on frontend.

    function maxBorrowable(
        uint256 uJimboAmount_
    ) public view returns (uint256 untaxed, uint256 taxed) {
        uint256 equivalentJimbo = uJimbo.previewRedeem(uJimboAmount_);
        uint256 jimboFloorPrice = pair
            .getPriceFromId(floorBin)
            .convert128x128PriceToDecimal();
        untaxed = (equivalentJimbo * jimboFloorPrice) / PRECISION;
        return (untaxed, (untaxed * 95) / 100);
    }

    /// borrow()
    /// -----------------------------------------------------------------------
    /// Pay 5% interest up front, borrow up to max amount of ETH of collateralized
    /// staked Jimbo.

    // Function to borrow ETH against uJIMBO. Can only have one active
    // borrow position at a time.

    function borrow(uint256 ethAmountOut_) external {
        // Check if user has an active borrow
        if (borrowedEth[msg.sender] == 0) {
            // Calculate how much uJIMBO to deposit
            uint256 jimboFloorPrice = pair
                .getPriceFromId(floorBin)
                .convert128x128PriceToDecimal();

            // round up since solidity rounds down
            uint256 jimboRequired = (
                ((ethAmountOut_ * PRECISION) / jimboFloorPrice)
            ) + 1;

            // 4626 impl should round up when dividing here for share count
            uint256 uJimboToDeposit = uJimbo.previewMint(jimboRequired);

            // Calculate fees and borrow amount
            uint256 floorFee = (ethAmountOut_ * 40) / 1000;
            uint256 jrsFee = (ethAmountOut_ * 10) / 1000;
            uint256 borrowAmount = (ethAmountOut_ -
                ((ethAmountOut_ * 50) / 1000)) - 1;

            // Adjust internal state
            uJimboDeposited[msg.sender] = uJimboToDeposit;
            borrowedEth[msg.sender] += ethAmountOut_;
            totalBorrowedEth += ethAmountOut_;

            // Deposit from user
            uJimbo.transferFrom(msg.sender, address(this), uJimboToDeposit);

            // Special case of recycle. Remove floor liquidity, transfer borrow
            // amount and JRS fee, then redeploy liquidity to floor. We need to
            // set rebalance to true so it doesn't trigger another recycle() call
            // inside the Jimbo.transfer() call during _addLiquidity, otherwise
            // the function will error.
            jimbo.setIsRebalancing(true);
            _removeFloorLiquidity();

            if (weth.balanceOf(address(this)) < ethAmountOut_)
                revert NotEnoughEthToBorrow();

            // Floor fee remains in contract
            weth.transfer(jrs, jrsFee);
            weth.transfer(msg.sender, borrowAmount);

            // Deploy rest of ETH (incl. floor fee) back into current floor
            // The additional ETH will be recalculated into a new floor upon
            // the next shift() call.
            _deployFloorLiquidity(weth.balanceOf(address(this)));
            jimbo.setIsRebalancing(false);
        } else {
            revert AlreadyBorrowed();
        }
    }

    // Repay all borrowed ETH and withdraw uJimbo
    function repayAndWithdraw() external {
        // Check if user has an active borrow
        if (borrowedEth[msg.sender] > 0) {
            // Calculate repayment and adjust internal state
            uint256 ethRepaid = borrowedEth[msg.sender];
            borrowedEth[msg.sender] = 0;
            totalBorrowedEth -= ethRepaid;

            // Return all uJimbo to user
            uint256 uJimboToReturn = uJimboDeposited[msg.sender];
            uJimboDeposited[msg.sender] = 0;

            // Transfer ETH to contract and uJimbo back to user
            weth.transferFrom(msg.sender, address(this), ethRepaid);
            uJimbo.transfer(msg.sender, uJimboToReturn);

            // Deploy ETH back to current floor bin, to be recalculated
            // upon next shift() call.
            jimbo.setIsRebalancing(true);
            _deployFloorLiquidity(ethRepaid);
            jimbo.setIsRebalancing(false);
        } else {
            revert NoActiveBorrows();
        }
    }

    /// -----------------------------------------------------------------------
    /// LIQUIDITY REBALANCING FUNCTIONS
    /// -----------------------------------------------------------------------

    /// @notice Calls all liquidity rebalancing functions in order
    /// @dev    Any non-executing functions will return false instead
    ///         of reverting to fail gracefully.
    ///
    ///         Rebalancing Logic Flow:
    ///         ---------------------------------------------------------------
    ///
    ///         1. Remove liquidity (remove floor bin last if applicable)
    ///         2. Set desired bin state (even if setting same values)
    ///         3. Add liquidity based on new bin state
    ///         NOTE that isRebalancing is set to true on Jimbo during this process
    ///         to prevent taxes during rebalancing.
    ///
    ///         ================
    ///
    ///         Shift():
    ///         Shifts ETH liquidity to the new floor bin and deploys anchors.
    ///         This is called when the active bin is above the trigger bin.
    ///
    ///         ================
    ///
    ///         Reset:
    ///         Resets the JIMBO liquidity starting at the active bin.
    ///         This is called when the active bin is below the anchor bin.
    ///
    ///         ================
    ///
    ///         Recycle:
    ///         Recycles any protocol-owned JIMBO in the floor bin.
    ///         This is called when the active bin is the floor bin.

    function rebalance() public {
        bool didShift = shift();
        bool didReset = reset();
        bool didRecycle = recycle();

        emit Rebalance(didShift, didReset, didRecycle);
    }

    /// Internal function for setting internal bin state.
    /// Called in shift() and reset().

    function _setBinState(
        uint24 floorBin_,
        uint24 anchorBin_,
        uint24 triggerBin_,
        uint24 maxBin_
    ) internal {
        floorBin = floorBin_;
        anchorBin = anchorBin_;
        triggerBin = triggerBin_;
        maxBin = maxBin_;

        emit BinsSet(floorBin, anchorBin, triggerBin, maxBin_);
    }

    /// Shift
    /// -----------------------------------------------------------------------

    function canShift() public view returns (bool) {
        return pair.getActiveId() > triggerBin;
    }

    function shift() public returns (bool) {
        if (canShift()) {
            // Let the token know the protocol is rebalancing
            jimbo.setIsRebalancing(true);

            // Get the active bin
            uint24 activeBin = pair.getActiveId();

            // Remove all non-floor bin liquidity (max bin -> anchor bin)
            _removeNonFloorLiquidity();

            // Remove all floor bin liquidity
            _removeFloorLiquidity();

            // Count the total JIMBO and ETH in the contract after liquidity removal
            uint256 totalJimboInPool = jimbo.balanceOf(address(this));
            uint256 totalEthInContract = weth.balanceOf(address(this));

            // Floor is based on total eth / circulating supply
            uint256 totalCirculatingJimbo = jimbo.totalSupply() -
                jimbo.balanceOf(address(0)) -
                totalJimboInPool;

            // Calculate the new target floor bin
            uint24 newFloorBin = _calculateNewFloorBin(
                totalEthInContract,
                totalCirculatingJimbo
            );

            // Calculate new anchor bin id
            // Make sure you use the new floor bin and not the stale one
            uint24 newAnchorBin = activeBin - newFloorBin > NUM_ANCHOR_BINS
                ? activeBin - NUM_ANCHOR_BINS
                : activeBin - 1;

            // Set internal bin state
            _setBinState({
                floorBin_: newFloorBin,
                anchorBin_: newAnchorBin, // this is not always true
                triggerBin_: activeBin + NUM_ANCHOR_BINS,
                maxBin_: activeBin + NUM_LIQ_BINS - 1 // decrement because we are adding inclusive of active bin
            });

            // Deploy all the JIMBO liquidity first
            _deployJimboLiquidity();

            // Deploy floor bin liquidity with 90% of all ETH in the contract
            _deployFloorLiquidity((weth.balanceOf(address(this)) * 90) / 100);

            // Use entire remaining weth balance in the contract to deploy anchors
            _deployAnchorLiquidity(weth.balanceOf(address(this)));

            // Let the token know we are done rebalancing to apply taxes
            jimbo.setIsRebalancing(false);
            return true;
        } else return false;
    }

    /// Reset
    /// -----------------------------------------------------------------------

    function canReset() public view returns (bool) {
        return (pair.getActiveId() < anchorBin);
    }

    function reset() public returns (bool) {
        if (canReset()) {
            // Let the token know the pool is currently rebalancing for taxes
            jimbo.setIsRebalancing(true);

            // Remove all JIMBO liquidity from the pool (except any JIMBO in floor)
            // in the condition when anchor bin = floor bin (see comments in the
            // function for details).
            _removeJimboLiquidity();

            // Update bin states
            uint24 activeBin = pair.getActiveId();

            _setBinState({
                floorBin_: floorBin,
                anchorBin_: activeBin,
                triggerBin_: activeBin + NUM_ANCHOR_BINS,
                maxBin_: activeBin + NUM_LIQ_BINS - 1
            });

            // Deploy Jimbo liquidity
            _deployJimboLiquidity();

            // Let the token know we are done rebalancing for taxes
            jimbo.setIsRebalancing(false);

            return true;
        } else return false;
    }

    /// Recycle
    /// -----------------------------------------------------------------------

    function canRecycle() public view returns (bool) {
        return pair.getActiveId() == floorBin;
    }

    /// @dev No need to set bin state here, as it is already set from reset()

    function recycle() public returns (bool) {
        if (canRecycle()) {
            // Let the token know the pool is currently rebalancing for taxes
            jimbo.setIsRebalancing(true);

            // Remove all the liquidity in the floor bin
            _removeFloorLiquidity();

            // Redeploy floor bin liquidity with only WETH
            _deployFloorLiquidity(weth.balanceOf(address(this)));

            // let the token know the pool is done rebalancing for taxes
            jimbo.setIsRebalancing(false);

            return true;
        } else return false;
    }

    /// -----------------------------------------------------------------------
    /// LIQUIDITY REBALANCE HELPERS: REMOVING LIQUIDITY
    /// -----------------------------------------------------------------------

    /// @notice Removes all liquidity from the floor bin.
    /// @dev We need to check if the pair still has liquidity in the floor bin
    /// when calling this function, because it's used in conjunction with
    /// _removeNonFloorLiquidity() in shift(). It's possible that floor bin
    /// == anchor bin when this function is called, so the floor liquidity
    /// may already have been removed by _removeNonFloorLiquidity(). We check
    /// the pair balance first to ensure that we are removing a non-zero amount
    /// of liquidity first so that we don't return an error from the LBPair.burn().

    function _removeFloorLiquidity() internal {
        uint256 floorBinLiquidityLPBalance = pair.balanceOf(
            address(this),
            floorBin
        );

        if (floorBinLiquidityLPBalance > 0) {
            uint256[] memory ids = new uint256[](1);
            uint256[] memory amounts = new uint256[](1);

            ids[0] = floorBin;
            amounts[0] = floorBinLiquidityLPBalance;

            pair.burn(address(this), address(this), ids, amounts);
        }
    }

    /// @notice Removes all ETH + JIMBO liquidity from max bin -> anchor bin.
    /// @dev Always remove bin inclusive of the anchor. However, in this
    /// case the anchor bin might be the floor bin. Please keep in mind
    /// this function will also remove the active bin liquidity as well.

    function _removeNonFloorLiquidity() internal {
        uint256 numberOfBinsToWithdraw = (maxBin - uint256(anchorBin)) + 1;

        uint256[] memory amounts = new uint256[](numberOfBinsToWithdraw);
        uint256[] memory ids = new uint256[](numberOfBinsToWithdraw);

        for (uint256 i = 0; i < numberOfBinsToWithdraw; i++) {
            ids[i] = maxBin - i;
            uint256 pairBalance = pair.balanceOf(address(this), maxBin - i);

            if (pairBalance == 0) {
                hardResetEnabled = true;
                return;
            }

            amounts[i] = pairBalance;
        }

        pair.burn(address(this), address(this), ids, amounts);
    }

    /// @notice Removes all JIMBO liquidity from max bin -> anchor.
    /// @dev Always remove bin inclusive of the anchor, except in the case
    /// when anchor bin = floor bin. This can happen when a large sell
    /// dumps JIMBO liquidity into the floor bin, and reset() has not been
    /// triggered yet because the pool state is updated after the transfer
    /// is facilitated. In this case, leave the JIMBO in the floor bin
    /// to be collected on a future recycle().

    function _removeJimboLiquidity() internal {
        uint256 numberOfBinsToWithdraw = (maxBin - uint256(anchorBin)) + 1;

        // will be recycled in reset() afterwards.
        if (anchorBin == floorBin) {
            numberOfBinsToWithdraw--;
        }

        uint256[] memory amounts = new uint256[](numberOfBinsToWithdraw);
        uint256[] memory ids = new uint256[](numberOfBinsToWithdraw);

        for (uint256 i = 0; i < numberOfBinsToWithdraw; i++) {
            ids[i] = maxBin - i;
            uint256 pairBalance = pair.balanceOf(address(this), maxBin - i);

            if (pairBalance == 0) {
                hardResetEnabled = true;
                return;
            }

            amounts[i] = pairBalance;
        }

        pair.burn(address(this), address(this), ids, amounts);
    }

    /// -----------------------------------------------------------------------
    /// LIQUIDITY REBALANCE HELPERS: ADDING LIQUIDITY
    /// -----------------------------------------------------------------------

    /// @notice Deploys all JIMBO in the contract as liquidity across 51 bins:
    /// 50 bins (1%) + 1 bin (50%).
    /// @dev We start deployment at active bin and do not worry about
    /// the composition fee even if there is external ETH LP in the active bin.
    /// This is because any "virtual swap" deploying at active bin into external
    /// LP sells JIMBO for ETH at a price that is at least the floor price.
    /// Even if active bin == floor bin when we deploy JIMBO liquidity,
    /// We can remove the extra JIMBO in the floor bin by calling recycle() after
    /// liquidity deployment is complete.

    function _deployJimboLiquidity() internal {
        uint24 activeBin = pair.getActiveId();

        int256[] memory deltaIds = new int256[](NUM_LIQ_BINS);
        uint256[] memory distributionX = new uint256[](NUM_LIQ_BINS);
        uint256[] memory distributionY = new uint256[](NUM_LIQ_BINS);

        // distribute 50% of tokens across 50 bins
        for (uint256 i = 0; i < NUM_LIQ_BINS - 1; i++) {
            deltaIds[i] = int256(i);
            distributionX[i] = (PRECISION * 1) / 100;
        }

        // distribute 50% of tokens to 51st bin
        deltaIds[50] = 50;
        distributionX[50] = (PRECISION * 50) / 100;

        // include the amount of token in the contract from prior recycles to deploy as liquidity
        uint256 tokenXbalance = jimbo.balanceOf(address(this));

        // we are only deploying token liquidity, so set Token Y (WETH) to 0.
        uint256 tokenYbalance = 0;

        _addLiquidity(
            deltaIds,
            distributionX,
            distributionY,
            tokenXbalance,
            tokenYbalance,
            activeBin
        );
    }

    /// @notice Deploys @amountEth_ as liquidity to the floor bin
    /// @param amountEth_ Precalculated amount of ETH to deploy as liquidity
    /// @dev In the case where active bin == floor bin, there may be external
    /// JIMBO liquidity in the floor bin that will trigger a bin composition
    /// "virtual swap", which will buy JIMBO for ETH at the floor price + a fee.
    /// This is fine, however, because we can remove the extra JIMBO in the floor
    /// bin that was bought by the "virtual swap" by calling recycle(), and selling
    /// the newly acquired JIMBO at a higher bin when they are redistributed in
    /// _deployJimboLiquidity(). The floor bin in TJ "lags" behind real floor because
    /// it's only updated when a shift() is triggered, so any composition swaps
    /// will be buying JIMBO with ETH under floor value.

    function _deployFloorLiquidity(uint256 amountEth_) internal {
        uint24 activeBin = pair.getActiveId();

        int256[] memory deltaIds = new int256[](1);
        uint256[] memory distributionX = new uint256[](1);
        uint256[] memory distributionY = new uint256[](1);

        deltaIds[0] = int256(int24(floorBin) - int24(activeBin));
        distributionX[0] = 0;
        distributionY[0] = (PRECISION * 100) / 100;

        _addLiquidity(
            deltaIds,
            distributionX,
            distributionY,
            0,
            amountEth_,
            activeBin
        );
    }

    /// @notice Deploys @amountEth_ as liquidity to the anchor bin(s).
    /// @param amountEth_ Precalculated amount of ETH to deploy as liquidity
    /// @dev When this function is called, we expect that the active bin is
    /// likely trading at least 5 bins above floor, since it is only ever
    /// called when the trigger bin is blown through. However, in rare
    /// situations where an insufficient number of bins are present to deploy
    /// the anchor liquidity (floor bin moves up faster than expected)
    /// we have an else statement to cover the edge case. In the edge case,
    /// we simply deploy all ETH liquidity to active bin - 1. This is the
    /// highest possible bin we can deploy the floor bin to, so in the worse
    /// case liquidity will get added on top of the floor bin.

    function _deployAnchorLiquidity(uint256 amountEth_) internal {
        uint24 activeBin = pair.getActiveId();

        if (activeBin - floorBin > NUM_ANCHOR_BINS) {
            int256[] memory deltaIds = new int256[](NUM_ANCHOR_BINS);
            uint256[] memory distributionX = new uint256[](NUM_ANCHOR_BINS);
            uint256[] memory distributionY = new uint256[](NUM_ANCHOR_BINS);

            deltaIds[0] = -1;
            distributionY[0] = ((PRECISION * 10) / 100);

            deltaIds[1] = -2;
            distributionY[1] = ((PRECISION * 15) / 100);

            deltaIds[2] = -3;
            distributionY[2] = ((PRECISION * 20) / 100);

            deltaIds[3] = -4;
            distributionY[3] = ((PRECISION * 25) / 100);

            deltaIds[4] = -5;
            distributionY[4] = ((PRECISION * 30) / 100);

            _addLiquidity(
                deltaIds,
                distributionX,
                distributionY,
                0,
                amountEth_,
                activeBin
            );
        } else {
            int256[] memory deltaIds = new int256[](1);
            uint256[] memory distributionX = new uint256[](1);
            uint256[] memory distributionY = new uint256[](1);

            deltaIds[0] = -1;
            distributionX[0] = 0;
            distributionY[0] = (PRECISION * 100) / 100;

            _addLiquidity(
                deltaIds,
                distributionX,
                distributionY,
                0,
                amountEth_,
                activeBin
            );
        }
    }

    /// @notice Brute forces to burn off all LP tokens in the contract
    /// and redeploys JIMBO liquidity. Should only be called when the
    /// flag is set by a faulty state when pulling LB liquidity.
    /// @dev This function iterates through each bin and pulls the
    /// liquidity for that bin only, up until max bin. Then it redeploys
    /// liquidity based on new calculations.

    function hardReset() external {
        // Ensure hard reset is enabled
        if (!hardResetEnabled) revert HardResetNotEnabled();

        jimbo.setIsRebalancing(true);

        uint256[] memory amounts = new uint256[](1);
        uint256[] memory ids = new uint256[](1);

        for (uint256 i = floorBin; i < maxBin + 1; i++) {
            ids[0] = i;
            uint256 pairBalance = pair.balanceOf(address(this), i);

            if (pairBalance == 0) {
                continue;
            }

            amounts[0] = pairBalance;
            pair.burn(address(this), address(this), ids, amounts);
        }

        _deployJimboLiquidity();

        // Deploy floor bin liquidity with 90% of all ETH in the contract
        _deployFloorLiquidity((weth.balanceOf(address(this))));

        jimbo.setIsRebalancing(false);
        hardResetEnabled = false;
    }

    /// @dev Internal function to add liq function
    function _addLiquidity(
        int256[] memory deltaIds,
        uint256[] memory distributionX,
        uint256[] memory distributionY,
        uint256 amountX,
        uint256 amountY,
        uint24 activeIdDesired
    ) internal {
        uint256 amountXmin = (amountX * 99) / 100; // We allow 1% amount slippage
        uint256 amountYmin = (amountY * 99) / 100; // We allow 1% amount slippage

        uint256 idSlippage = activeIdDesired - pair.getActiveId();

        ILBRouter.LiquidityParameters memory liquidityParameters = ILBRouter
            .LiquidityParameters(
                IERC20(address(jimbo)),
                weth,
                BIN_STEPS,
                amountX,
                amountY,
                amountXmin,
                amountYmin,
                activeIdDesired, //activeIdDesired
                idSlippage,
                deltaIds,
                distributionX,
                distributionY,
                address(this),
                address(this),
                block.timestamp
            );

        router.addLiquidity(liquidityParameters);
    }

    /// -----------------------------------------------------------------------
    /// MISC HELPERS AND VIEWS
    /// -----------------------------------------------------------------------

    /// @notice internal helper to find the new floor bin ID.
    /// @param totalEth_ Total ETH in the contract after liquidity removal
    /// @param totalCirculatingJimbo_ Total circulating JIMBO after liquidity removal
    /// @dev LBPair.getIdFromPrice() is not accurate, so we iterate through
    /// LPPair.getPriceFromId() starting from floor bin -> active bin to find
    /// the floor bin. In each increment, we check to see if the next bin's
    /// price is greater than the new floor price. If it is, we break and return.
    /// We expect to increment at most 50 bins so no need for binary search.
    /// @dev We add virtual ETH owed to the total ETH calculation to account
    /// for borrowing activity when calculating new floor.

    function _calculateNewFloorBin(
        uint256 totalEth_,
        uint256 totalCirculatingJimbo_
    ) internal view returns (uint24) {
        uint256 targetFloorPrice = ((totalBorrowedEth + totalEth_) *
            PRECISION) / totalCirculatingJimbo_;
        uint256 priceAtCurrentBin;
        uint24 targetFloorBin;
        uint24 activeBin = pair.getActiveId();

        // look for a new floor bin, starting at the active bin and
        // going down to the current floor bin. If a new floor bin
        // is not found, return the current floor bin
        for (
            targetFloorBin = activeBin - 1;
            targetFloorBin > floorBin;
            targetFloorBin--
        ) {
            priceAtCurrentBin = (pair.getPriceFromId(targetFloorBin))
                .convert128x128PriceToDecimal();

            if (targetFloorPrice > priceAtCurrentBin) return targetFloorBin;
        }

        return floorBin;
    }

    function getFloorLiqBin() external view returns (uint256, uint256) {
        return pair.getBin(floorBin);
    }

    function getFloorPrice() external view returns (uint256) {
        return (pair.getPriceFromId(floorBin)).convert128x128PriceToDecimal();
    }

    function getPosition(
        address user
    ) external view returns (uint256, uint256) {
        uint256 uJimboLocked = uJimboDeposited[user];
        uint256 ethBorrowed = borrowedEth[user];

        return (uJimboLocked, ethBorrowed);
    }
}
