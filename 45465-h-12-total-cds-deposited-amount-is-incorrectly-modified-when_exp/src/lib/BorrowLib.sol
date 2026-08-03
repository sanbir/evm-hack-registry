// SPDX-License-Identifier: MIT

pragma solidity 0.8.22;

import {State, IABONDToken} from "../interface/IAbond.sol";
import "../interface/ITreasury.sol";
import "../interface/IUSDa.sol";
import "../interface/IBorrowing.sol";
import "../interface/IGlobalVariables.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";

library BorrowLib {
    event Deposit(
        address user,
        uint64 index,
        uint256 depositedAmount,
        uint256 normalizedAmount,
        uint256 depositedTime,
        uint128 ethPrice,
        uint256 borrowAmount,
        uint64 strikePrice,
        uint256 optionsFees,
        IOptions.StrikePrice strikePricePercent,
        uint8 APR,
        uint256 aBondCr
    );
    event Withdraw(
        address user,
        uint64 index,
        uint256 withdrawTime,
        uint128 withdrawAmount,
        uint128 noOfAbond,
        uint256 borrowDebt
    );

    uint128 constant PRECISION = 1e6;
    uint128 constant CUMULATIVE_PRECISION = 1e7;
    uint128 constant RATIO_PRECISION = 1e4;
    uint128 constant RATE_PRECISION = 1e27;
    uint128 constant USDA_PRECISION = 1e12;
    uint128 constant LIQ_AMOUNT_PRECISION = 1e10;
    uint128 constant OPTIONS_FEES_PRECISION = 1e10;

    string public constant name = "Borrow";
    string public constant version = "1";
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    /**
     * @dev calculates the 50% of the input value
     * @param amount input amount
     */
    function calculateHalfValue(uint256 amount) public pure returns (uint128) {
        return uint128((amount * 50) / 100);
    }

    /**
     * @dev calculates the normalized value based on given cumulative rate
     * @param amount amount
     * @param cumulativeRate cumulative rate
     */
    function calculateNormAmount(
        uint256 amount,
        uint256 cumulativeRate
    ) public pure returns (uint256) {
        return (amount * RATE_PRECISION) / cumulativeRate;
    }

    /**
     * @dev calulates debt amount based on given cumulative rate
     * @param amount amount
     * @param cumulativeRate cumulative rate
     */
    function calculateDebtAmount(
        uint256 amount,
        uint256 cumulativeRate
    ) public pure returns (uint256) {
        return (amount * cumulativeRate) / RATE_PRECISION;
    }

    /**
     * @dev calculate the options fees per second
     */
    function calculateOptionsFeesPerSec(
        uint128 optionsFees
    ) public pure returns (uint128) {
        // gets the options fees per second by dividing the options fees by number of seconds in 30 days
        return (optionsFees * OPTIONS_FEES_PRECISION) / 30 days;
    }

    function calculateDownsideProtected(
        uint128 amount,
        uint128 currentEthPrice,
        uint128 depositEthPrice
    ) public pure returns (uint128) {
        if (currentEthPrice < depositEthPrice) {
            return (amount * (depositEthPrice - currentEthPrice)) / (100 * USDA_PRECISION);
        } else {
            return 0;
        }
    }

    /**
     * @dev calculates the ratio of current eth price to the deposit eth price
     * @param depositEthPrice eth pricd at deposit
     * @param currentEthPrice current eth Price
     */
    function calculateEthPriceRatio(
        uint128 depositEthPrice,
        uint128 currentEthPrice
    ) public pure returns (uint128) {
        return (currentEthPrice * 10000) / depositEthPrice;
    }

    /**
     * @dev calculates discounted eth
     * @param amount deposited collateral amount
     * @param ethPrice current eth price
     */
    function calculateDiscountedETH(
        uint256 amount,
        uint128 ethPrice
    ) public pure returns (uint256) {
        // 80% of half of the deposited amount
        return (80 * calculateHalfValue(amount) * ethPrice) / (USDA_PRECISION * 1e4);
    }

    /**
     * @dev calculates return to abond
     * @param depositedAmount deposited collateral
     * @param depositEthPrice eth price at deposit
     * @param returnToTreasury return to treasury(debt)
     */
    function calculateReturnToAbond(
        uint128 depositedAmount,
        uint128 depositEthPrice,
        uint128 returnToTreasury
    ) public pure returns (uint128) {
        // 10% of the remaining amount
        return (((((depositedAmount * depositEthPrice) / USDA_PRECISION) / 100) - returnToTreasury) * 10) / 100;
    }

    /**
     * @dev calculates the ratio of cds pool value to the eth value
     * @param amount depositing collateral amount in eth
     * @param currentEthPrice current eth price
     * @param lastEthprice last recorded eth price
     * @param noOfDeposits no of deposirs till now in borrowing
     * @param totalCollateralInETH total collateral deposited in eth
     * @param latestTotalCDSPool total cds deposited amount
     * @param previousData last recorded global omnichain data
     */
    function calculateRatio(
        uint256 amount,
        uint128 currentEthPrice,
        uint128 lastEthprice,
        uint256 noOfDeposits,
        uint256 totalCollateralInETH,
        uint256 latestTotalCDSPool,
        IGlobalVariables.OmniChainData memory previousData
    ) public pure returns (uint64, IGlobalVariables.OmniChainData memory) {
        uint256 netPLCdsPool;

        // Calculate net P/L of CDS Pool
        // if the current eth price is high
        if (currentEthPrice > lastEthprice) {
            // profit, multiply the price difference with total collateral
            netPLCdsPool = (((currentEthPrice - lastEthprice) * totalCollateralInETH) / USDA_PRECISION) / 100;
        } else {
            // loss, multiply the price difference with total collateral
            netPLCdsPool = (((lastEthprice - currentEthPrice) * totalCollateralInETH) / USDA_PRECISION) / 100;
        }

        uint256 currentVaultValue;
        uint256 currentCDSPoolValue;

        // Check it is the first deposit
        if (noOfDeposits == 0) {
            // Calculate the ethVault value
            previousData.vaultValue = amount * currentEthPrice;
            // Set the currentEthVaultValue to lastEthVaultValue for next deposit
            currentVaultValue = previousData.vaultValue;

            // Get the total amount in CDS
            // lastTotalCDSPool = cds.totalCdsDepositedAmount();
            previousData.totalCDSPool = latestTotalCDSPool;

            // BAsed on the eth prices, add or sub, profit and loss respectively
            if (currentEthPrice >= lastEthprice) {
                currentCDSPoolValue = previousData.totalCDSPool + netPLCdsPool;
            } else {
                currentCDSPoolValue = previousData.totalCDSPool - netPLCdsPool;
            }

            // Set the currentCDSPoolValue to lastCDSPoolValue for next deposit
            previousData.cdsPoolValue = currentCDSPoolValue;
            currentCDSPoolValue = currentCDSPoolValue * USDA_PRECISION;
        } else {
            // find current vault value by adding current depositing amount
            currentVaultValue = previousData.vaultValue + (amount * currentEthPrice);
            previousData.vaultValue = currentVaultValue;

            // BAsed on the eth prices, add or sub, profit and loss respectively
            if (currentEthPrice >= lastEthprice) {
                previousData.cdsPoolValue += netPLCdsPool;
            } else {
                previousData.cdsPoolValue -= netPLCdsPool;
            }
            previousData.totalCDSPool = latestTotalCDSPool;
            currentCDSPoolValue = previousData.cdsPoolValue * USDA_PRECISION;
        }

        // Calculate ratio by dividing currentEthVaultValue by currentCDSPoolValue,
        // since it may return in decimals we multiply it by 1e6
        uint64 ratio = uint64((currentCDSPoolValue * CUMULATIVE_PRECISION) / currentVaultValue);
        return (ratio, previousData);
    }

    /**
     * @dev calculates cumulative rate
     * @param noOfBorrowers total number of borrowers in the protocol
     * @param ratePerSec interest rate per second
     * @param lastEventTime last event timestamp
     * @param lastCumulativeRate previous cumulative rate
     */
    function calculateCumulativeRate(
        uint128 noOfBorrowers,
        uint256 ratePerSec,
        uint128 lastEventTime,
        uint256 lastCumulativeRate
    ) public view returns (uint256) {
        uint256 currentCumulativeRate;

        // If there is no borrowers in the protocol
        if (noOfBorrowers == 0) {
            // current cumulative rate is same as ratePeSec
            currentCumulativeRate = ratePerSec;
        } else {
            // Find time interval between last event and now
            uint256 timeInterval = uint128(block.timestamp) - lastEventTime;
            //calculate cumulative rate
            currentCumulativeRate = lastCumulativeRate * _rpow(ratePerSec, timeInterval, RATE_PRECISION);
            currentCumulativeRate = currentCumulativeRate / RATE_PRECISION;
        }
        return currentCumulativeRate;
    }

    /**
     * @dev tokensToLend based on LTV
     * @param depositedAmount deposited collateral amount
     * @param ethPrice current eth price
     * @param LTV ltv of the protocol
     */
    function tokensToLend(
        uint256 depositedAmount,
        uint128 ethPrice,
        uint8 LTV
    ) public pure returns (uint256) {
        uint256 tokens = (depositedAmount * ethPrice * LTV) / (USDA_PRECISION * RATIO_PRECISION);
        return tokens;
    }

    /**
     * @dev calculates the abond amount to mint for the deposited amount
     * @param _amount deposited collateral amount
     * @param _bondRatio abond to usda ratio
     */
    function abondToMint(
        uint256 _amount,
        uint64 _bondRatio
    ) public pure returns (uint128 amount) {
        amount = (uint128(_amount) * USDA_PRECISION) / _bondRatio;
    }

    /**
     * @dev calculates the base number to multilpy with currrent apr
     * @param usdaPrice usda price with 1e4 precision
     */
    function calculateBaseToMultiply(
        uint32 usdaPrice
    ) public pure returns (uint8 baseToMultiply) {
        // usda price has 10000 precision
        if (usdaPrice < 9500) {
            // baseToMultiply has 10 precision
            baseToMultiply = 50;
        } else if (usdaPrice < 9700 && usdaPrice >= 9500) {
            baseToMultiply = 30;
        } else if (usdaPrice < 9800 && usdaPrice >= 9700) {
            baseToMultiply = 20;
        } else if (usdaPrice < 9900 && usdaPrice >= 9800) {
            baseToMultiply = 15;
        } else if (usdaPrice < 10100 && usdaPrice >= 9900) {
            baseToMultiply = 10;
        } else if (usdaPrice < 10200 && usdaPrice >= 10100) {
            baseToMultiply = 8;
        } else if (usdaPrice < 10500 && usdaPrice >= 10200) {
            baseToMultiply = 5;
        } else {
            baseToMultiply = 1;
        }
    }

    /**
     * @dev calculates new apr
     * @param usdaPrice usda price with 1e4 precision
     */
    function calculateNewAPRToUpdate(
        uint32 usdaPrice
    ) public pure returns (uint128 ratePerSec, uint8 newAPR) {
        if (usdaPrice == 0) revert IBorrowing.Borrow_NeedsMoreThanZero();
        newAPR = 5 * calculateBaseToMultiply(usdaPrice);
        if (newAPR == 250) {
            ratePerSec = 1000000007075835619725814915;
        } else if (newAPR == 150) {
            ratePerSec = 1000000004431822129783699001;
        } else if (newAPR == 100) {
            ratePerSec = 1000000003022265980097387650;
        } else if (newAPR == 75) {
            ratePerSec = 1000000002293273137447730714;
        } else if (newAPR == 50) {
            ratePerSec = 1000000001547125957863212448;
        } else if (newAPR == 40) {
            ratePerSec = 1000000001243680656318820312;
        } else if (newAPR == 25) {
            ratePerSec = 1000000000782997609082909351;
        } else if (newAPR == 5) {
            ratePerSec = 1000000000158153903837946257;
        }
    }

    /**
     * @dev get abond yields for the given abond amount
     * @param user abond holder address
     * @param aBondAmount redeeming abond amount
     * @param abondAddress abond token address
     * @param treasuryAddress treasury address
     */
    function getAbondYields(
        address user,
        uint128 aBondAmount,
        address abondAddress,
        address treasuryAddress
    ) public view returns (uint128, uint256, uint256) {
        // check abond amount is non zewro
        if (aBondAmount == 0) revert IBorrowing.Borrow_NeedsMoreThanZero();

        IABONDToken abond = IABONDToken(abondAddress);
        // get user abond state
        State memory userState = abond.userStates(user);
        // check user have enough abond
        if (aBondAmount > userState.aBondBalance) revert IBorrowing.Borrow_InsufficientBalance();

        ITreasury treasury = ITreasury(treasuryAddress);
        // calculate the yields
        uint256 redeemableAmount = treasury.calculateYieldsForExternalProtocol(user, aBondAmount);
        uint128 depositedAmount = (aBondAmount * userState.ethBacked) / 1e18;
        // usda to abond gained by liqudation
        uint128 usdaToAbondRatioLiq = uint64((treasury.usdaGainedFromLiquidation() * RATE_PRECISION) / abond.totalSupply());
        uint256 usdaToTransfer = (usdaToAbondRatioLiq * aBondAmount) / RATE_PRECISION;

        return (depositedAmount, redeemableAmount, usdaToTransfer);
    }

    /**
     * @dev get liquidation amount proportions to get from each chains
     * @param _liqAmount liquidation amount needed
     * @param _totalCdsDepositedAmount total cds amount in this chain
     * @param _totalGlobalCdsDepositedAmount total global cds amount
     * @param _totalAvailableLiqAmount available liqidation amount in cds in this chain
     * @param _totalGlobalAvailableLiqAmountAmount available global liquidation amount in cds
     */
    function getLiquidationAmountProportions(
        uint256 _liqAmount,
        uint256 _totalCdsDepositedAmount,
        uint256 _totalGlobalCdsDepositedAmount,
        uint256 _totalAvailableLiqAmount,
        uint256 _totalGlobalAvailableLiqAmountAmount
    ) public pure returns (uint256) {
        // Calculate other chain cds deposited amount
        uint256 otherChainCDSAmount = _totalGlobalCdsDepositedAmount - _totalCdsDepositedAmount;

        // calculate other chain available liq amount in cds
        uint256 totalAvailableLiqAmountInOtherChain = _totalGlobalAvailableLiqAmountAmount - _totalAvailableLiqAmount;

        // find the share of each chain
        uint256 share = (otherChainCDSAmount * LIQ_AMOUNT_PRECISION) / _totalGlobalCdsDepositedAmount;
        // amount to get from other chain
        uint256 liqAmountToGet = (_liqAmount * share) / LIQ_AMOUNT_PRECISION;
        // amount to get from this chain
        uint256 liqAmountRemaining = _liqAmount - liqAmountToGet;

        // if tha other chain dont have any available liquidation amount
        if (totalAvailableLiqAmountInOtherChain == 0) {
            liqAmountToGet = 0;
        } else {
            // if the other chain dont have sufficient liq amount to get, get the remaining from thsi chain itself
            if (totalAvailableLiqAmountInOtherChain < liqAmountToGet) {
                liqAmountToGet = totalAvailableLiqAmountInOtherChain;
            } else {
                if (
                    totalAvailableLiqAmountInOtherChain > liqAmountToGet &&
                    _totalAvailableLiqAmount < liqAmountRemaining
                ) {
                    liqAmountToGet += liqAmountRemaining - _totalAvailableLiqAmount;
                } else {
                    liqAmountToGet = liqAmountToGet;
                }
            }
        }
        return liqAmountToGet;
    }

    function getCdsProfitsProportions(
        uint128 _liqAmount,
        uint128 _liqAmountToGetFromOtherChain,
        uint128 _cdsProfits
    ) public pure returns (uint128) {
        uint128 share = (_liqAmountToGetFromOtherChain * LIQ_AMOUNT_PRECISION) / _liqAmount;
        uint128 cdsProfitsForOtherChain = (_cdsProfits * share) / LIQ_AMOUNT_PRECISION;

        return cdsProfitsForOtherChain;
    }

    /**
     * @dev gets the options fees, the borrower needs to pay to renew
     * @param index the index of the position
     */
    function getOptionFeesToPay(
        ITreasury treasury,
        uint64 index
    ) public view returns (uint256) {
        // Get the deposit details
        ITreasury.GetBorrowingResult memory getBorrowingResult = treasury.getBorrowing(msg.sender, index);
        ITreasury.DepositDetails memory depositDetail = getBorrowingResult.depositDetails;

        // check if borrowerIndex in BorrowerDetails of the msg.sender is greater than or equal to Index
        if (getBorrowingResult.totalIndex >= index) {
            // check the position is not withdrew or liquidated
            if (depositDetail.withdrawed && depositDetail.liquidated)
                revert IBorrowing.Borrow_AlreadyWithdrewOrLiquidated();

            // check the user is eligible to renew position
            if (
                block.timestamp <
                depositDetail.optionsRenewedTimeStamp + 15 days &&
                block.timestamp >
                depositDetail.optionsRenewedTimeStamp + 30 days
            ) revert IBorrowing.Borrow_DeadlinePassed();

            // calculate time difference from deposit to current time
            uint256 secondsPassedSinceDeposit = block.timestamp - depositDetail.optionsRenewedTimeStamp;

            // calculate options fees per second
            uint128 optionsFeesPerSec = calculateOptionsFeesPerSec(depositDetail.optionFees);

            // calculate options fees needs to pay by multiplying timw difference and options fees per second
            //? i.e position will be renewed for 30 days from now. If 10 days have been passed since deposit,
            //? then the total validity for 80% LTV is 40 days from deposit
            uint256 optionsFeesNeedsToPay = (optionsFeesPerSec * secondsPassedSinceDeposit) / OPTIONS_FEES_PRECISION;

            //return options fees needs to pay
            return optionsFeesNeedsToPay;
        } else {
            // revert if the entered index is not present for the borrower
            revert IBorrowing.Borrow_InvalidIndex();
        }
    }

    function calculateCollateralToReturn(
        IBorrowing.CalculateCollateralToReturn_Param memory params
    ) public view returns (IBorrowing.CalculateCollateralToReturn_Result memory) {
        uint128 collateralToReturn;
        //Calculate current depositedAmount value
        uint128 depositedAmountvalue = (params.depositDetail.depositedAmountInETH * params.depositDetail.ethPriceAtDeposit) / params.ethPrice;
        uint128 collateralRemainingInWithdraw;
        // If the health is greater than 1
        if (params.borrowingHealth > 10000) {
            // If the ethPrice is higher than deposit ethPrice,call withdrawOption in options contract
            collateralToReturn = (depositedAmountvalue + params.options.calculateStrikePriceGains(
                        params.depositDetail.depositedAmountInETH,
                        params.depositDetail.strikePrice,
                        params.ethPrice
                    )
                );
            // increment the difference between collatearla to  return and deposited amount in collateralRemainingInWithdraw
            collateralRemainingInWithdraw = params.depositDetail.depositedAmountInETH - collateralToReturn;
            params.collateralRemainingInWithdraw += collateralRemainingInWithdraw;
            params.omniChainData.collateralRemainingInWithdraw += collateralRemainingInWithdraw;
            // increment the difference between collatearl to return and deposited amount
            // in collateralValueRemainingInWithdraw in usd
            params.collateralValueRemainingInWithdraw += (collateralRemainingInWithdraw *params.ethPrice);
            params.omniChainData.collateralValueRemainingInWithdraw += (collateralRemainingInWithdraw *params.ethPrice);
            // If the health is one collateralToReturn is depositedAmountvalue itself
        } else if (params.borrowingHealth == 10000) {
            collateralToReturn = depositedAmountvalue;
            // If the health is between 0.8 and 1 collateralToReturn is depositedAmountInETH itself
        } else if (
            8000 < params.borrowingHealth && params.borrowingHealth < 10000
        ) {
            collateralToReturn = params.depositDetail.depositedAmountInETH;
        } else {
            revert IBorrowing.Borrow_BorrowHealthLow();
        }
        // Calculate the 50% of colllateral to return

        collateralToReturn = calculateHalfValue(params.depositDetail.depositedAmountInETH) - collateralRemainingInWithdraw;
        return IBorrowing.CalculateCollateralToReturn_Result(
                collateralToReturn,
                params.collateralRemainingInWithdraw,
                params.collateralValueRemainingInWithdraw,
                params.omniChainData
            );
    }

    /**
     * @dev getting cumulative value from CDS
     * @param ethPrice ETH price
     */
    function updateCumulativeValueInCDS(
        IGlobalVariables globalVariables,
        CDSInterface cds,
        uint64 ethPrice
    ) public returns (uint128, bool) {
        IGlobalVariables.OmniChainData memory omniChainData = globalVariables.getOmniChainData();
        // Calculate the cumulatice value
        CDSInterface.CalculateValueResult memory result = cds.calculateCumulativeValue(
                omniChainData.totalVolumeOfBorrowersAmountinWei,
                omniChainData.totalCdsDepositedAmount,
                ethPrice
            );
        // Set the cumulative value
        return cds.getCumulativeValue(
                omniChainData,
                result.currentValue,
                result.gains
            );
    }

    /**
     * @dev Transfer USDa token to the borrower
     * @param borrower Address of the borrower to transfer
     * @param amount deposited amount of the borrower
     * @param collateralPrice current collateral price
     * @param optionFees option fees paid by borrower
     */
    function transferToken(
        IUSDa usda,
        uint8 LTV,
        address treasuryAddress,
        address borrower,
        uint256 amount,
        uint128 collateralPrice,
        uint256 optionFees
    ) public returns (uint256 tokensToMint) {
        // Check the borrower address is not a non zero address
        if (borrower == address(0))
            revert IBorrowing.Borrow_MustBeNonZeroAddress(borrower);
        // Check the LTV is not 0
        if (LTV == 0) revert IBorrowing.Borrow_LTVIsZero();

        // tokenValueConversion is in USD, and our stablecoin is pegged to USD in 1:1 ratio
        // Hence if tokenValueConversion = 1, then equivalent stablecoin tokens = tokenValueConversion

        //Call the mint function in USDa
        //Mint 80% - options fees to borrower

        tokensToMint = tokensToLend(amount, collateralPrice, LTV);
        bool minted = usda.mint(borrower, (tokensToMint - optionFees));

        if (!minted) revert IBorrowing.Borrow_MintFailed();

        //Mint options fees to treasury
        bool treasuryMint = usda.mint(treasuryAddress, optionFees);

        if (!treasuryMint) revert IBorrowing.Borrow_MintFailed();
    }

    /**
     * @dev Transfer Abond token to the borrower
     * @param toAddress Address of the borrower to transfer
     * @param index index of the position
     * @param amount adond amount to transfer
     */

    function mintAbondToken(
        IABONDToken abond,
        uint64 bondRatio,
        address toAddress,
        uint64 index,
        uint256 amount
    ) public returns (uint128) {
        // Check the borrower address is not a non zero address
        if (toAddress == address(0))
            revert IBorrowing.Borrow_MustBeNonZeroAddress(toAddress);
        // Check the ABOND amount is not a zero
        if (amount == 0) revert IBorrowing.Borrow_NeedsMoreThanZero();

        // ABOND:USDa = 4:1
        amount = abondToMint(amount, bondRatio);

        //Call the mint function in ABONDToken
        bool minted = abond.mint(toAddress, index, amount);

        if (!minted) revert IBorrowing.Borrow_MintFailed();

        return uint128(amount);
    }

    /**
     * @dev renew the position by 30 days
     * @param index index of the position to renew
     */
    function renewOptions(
        IBorrowing.Interfaces memory interfaces,
        uint64 index
    ) external returns (bool) {
        // calculate options fees needs to pay to renew
        uint256 optionsFeesNeedsToPay = getOptionFeesToPay(interfaces.treasury,index);

        // check whether the user has enough options fees to pay
        if (interfaces.usda.balanceOf(msg.sender) < optionsFeesNeedsToPay) revert IBorrowing.Borrow_InsufficientBalance();

        // transfer the options fees from user to treasury
        bool sent = interfaces.usda.transferFrom(msg.sender, address(interfaces.treasury), optionsFeesNeedsToPay);

        if (!sent) revert IBorrowing.Borrow_USDaTransferFailed();

        // getting omnichain global data
        IGlobalVariables.OmniChainData memory omniChainData = interfaces.globalVariables.getOmniChainData();

        // updating last cumulative rate
        omniChainData.lastCumulativeRate = interfaces.cds.calculateCumulativeRate(uint128(optionsFeesNeedsToPay));
        omniChainData.totalCdsDepositedAmountWithOptionFees += optionsFeesNeedsToPay;

        // updating omnichain data
        interfaces.globalVariables.setOmniChainData(omniChainData);

        return true;
    }

    function deposit(
        IBorrowing.BorrowLibDeposit_Params memory libParams,
        IBorrowing.BorrowDepositParams memory params,
        IBorrowing.Interfaces memory interfaces,
        mapping(IBorrowing.AssetName => address assetAddress) storage assetAddress
    ) public returns (uint256) {
        uint256 depositingAmount = params.depositingAmount;
        // Check the deposting amount is non zero
        if (params.depositingAmount == 0) revert IBorrowing.Borrow_NeedsMoreThanZero();

        // Calculate the depsoting amount in ETH
        params.depositingAmount = (libParams.exchangeRate * params.depositingAmount) / 1 ether;

        // Get global omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = interfaces.globalVariables.getOmniChainData();
        uint64 ratio;
        //Call calculateInverseOfRatio function to find ratio
        (ratio, omniChainData) = calculateRatio(
            params.depositingAmount,
            uint128(libParams.ethPrice),
            libParams.lastEthprice,
            omniChainData.totalNoOfDepositIndices,
            omniChainData.totalVolumeOfBorrowersAmountinWei,
            omniChainData.totalCdsDepositedAmount - omniChainData.downsideProtected,
            omniChainData
        );
        // Check whether the cds have enough funds to give downside prottection to borrower
        if (ratio < (2 * RATIO_PRECISION)) revert IBorrowing.Borrow_NotEnoughFundInCDS();

        // Call calculateOptionPrice in options contract to get options fees
        uint256 optionFees = interfaces.options.calculateOptionPrice(
            libParams.ethPrice,
            params.volatility,
            params.depositingAmount,
            params.strikePercent
        );
        //Update the cumulative value in cds since, the cds amount is used to burn
        (omniChainData.cumulativeValue, omniChainData.cumulativeValueSign) = updateCumulativeValueInCDS(
            interfaces.globalVariables,
            interfaces.cds,
            uint64(libParams.ethPrice)
        );
        // If the collateral is other than ETH, get the collateral by transferFrom function in ERC20
        if (params.assetName != IBorrowing.AssetName.ETH) {
            bool sent = IERC20(assetAddress[params.assetName]).transferFrom(msg.sender, address(interfaces.treasury), depositingAmount);
            if (!sent) revert IBorrowing.Borrow_USDaTransferFailed();
        }
        //Call the deposit function in Treasury contract
        ITreasury.DepositResult memory depositResult = interfaces.treasury.deposit{
            value: params.assetName == IBorrowing.AssetName.ETH ? params.depositingAmount : 0
        }(
            msg.sender,
            libParams.ethPrice,
            uint64(block.timestamp),
            params.assetName,
            params.depositingAmount
        );

        //Check whether the deposit is successfull
        if (!depositResult.hasDeposited) revert IBorrowing.Borrow_DepositFailed();

        // Get the ABOND cumulative rate for this index
        uint128 aBondCr = interfaces.treasury.getCumulativeRate(ITreasury.Protocol.Ionic);
        // If the collateral is ETH, set ABOND data, since ETH only is deposited in External protocol
        if (params.assetName == IBorrowing.AssetName.ETH) {
            interfaces.abond.setAbondData(
                msg.sender,
                depositResult.borrowerIndex,
                calculateHalfValue(params.depositingAmount),
                aBondCr
            );
        }
        // Call the transfer function to mint USDa
        uint256 tokensToMint = transferToken(
            interfaces.usda,
            libParams.LTV,
            address(interfaces.treasury),
            msg.sender,
            params.depositingAmount,
            libParams.ethPrice,
            optionFees
        );

        // Get global omnichain data
        IGlobalVariables.CollateralData memory collateralData = interfaces.globalVariables.getOmniChainCollateralData(params.assetName);

        // Call calculateCumulativeRate in cds to split fees to cds users
        omniChainData.lastCumulativeRate = interfaces.cds.calculateCumulativeRate(uint128(optionFees));
        // Modify omnichain data
        omniChainData.totalCdsDepositedAmountWithOptionFees += optionFees;

        //Get the deposit details from treasury
        ITreasury.GetBorrowingResult memory getBorrowingResult = interfaces.treasury.getBorrowing(msg.sender, depositResult.borrowerIndex);
        ITreasury.DepositDetails memory depositDetail = getBorrowingResult.depositDetails;
        // Update the borrower details for this index
        depositDetail.depositedAmount = uint128(depositingAmount);
        depositDetail.borrowedAmount = uint128(tokensToMint);
        depositDetail.optionFees = uint128(optionFees);
        depositDetail.APR = libParams.APR;
        depositDetail.exchangeRateAtDeposit = libParams.exchangeRate;

        //Update variables in treasury
        interfaces.treasury.updateHasBorrowed(msg.sender, true);
        interfaces.treasury.updateTotalBorrowedAmount(msg.sender, tokensToMint);

        // Calculate normalizedAmount
        uint256 normalizedAmount = calculateNormAmount(tokensToMint, libParams.lastCumulativeRate);

        // Update the borrower details for this index
        depositDetail.normalizedAmount = uint128(normalizedAmount);
        depositDetail.strikePrice = params.strikePrice * uint128(params.depositingAmount);

        //Update the deposit details
        interfaces.treasury.updateDepositDetails(
            msg.sender,
            depositResult.borrowerIndex,
            depositDetail
        );

        // Calculate normalizedAmount of Protocol
        libParams.totalNormalizedAmount += normalizedAmount;

        // updating global data
        omniChainData.normalizedAmount += normalizedAmount;
        // If its the first index of the borrower, then increment the numbers of borrowers in the protocol
        if (depositResult.borrowerIndex == 1) {
            ++omniChainData.noOfBorrowers;
        }
        // Incrememt each index
        ++omniChainData.totalNoOfDepositIndices;
        // Update omnichain data
        omniChainData.totalVolumeOfBorrowersAmountinWei += params.depositingAmount;
        omniChainData.totalVolumeOfBorrowersAmountinUSD += (libParams.ethPrice * params.depositingAmount);
        // Update individual collateral data
        ++collateralData.noOfIndices;
        collateralData.totalDepositedAmountInETH += params.depositingAmount;
        collateralData.totalDepositedAmount += depositingAmount;
        // Update the updated individual collateral data and omnichain data in global variables
        interfaces.globalVariables.updateCollateralData(params.assetName,collateralData);
        interfaces.globalVariables.setOmniChainData(omniChainData);

        // Emit Deposit event
        emit Deposit(
            msg.sender,
            depositResult.borrowerIndex,
            params.depositingAmount,
            normalizedAmount,
            uint64(block.timestamp),
            libParams.ethPrice,
            tokensToMint,
            params.strikePrice,
            optionFees,
            params.strikePercent,
            libParams.APR,
            aBondCr
        );

        return libParams.totalNormalizedAmount;
    }

    function withdraw(
        ITreasury.DepositDetails memory depositDetail,
        IBorrowing.BorrowWithdraw_Params memory params,
        IBorrowing.Interfaces memory interfaces
    ) external returns (IBorrowing.BorrowWithdraw_Result memory) {
        // Get omnichain data
        IGlobalVariables.OmniChainData memory omniChainData = interfaces.globalVariables.getOmniChainData();
        IGlobalVariables.CollateralData memory collateralData = interfaces.globalVariables.getOmniChainCollateralData(depositDetail.assetName);

        // Check if user amount in the Index has been liquidated or not
        if (depositDetail.liquidated) revert IBorrowing.Borrow_AlreadyLiquidated();

        // check if withdrawed in depositDetail in borrowing of msg.seader is false or not
        if (!depositDetail.withdrawed) {
            // Calculate the borrowingHealth
            uint128 borrowingHealth = calculateEthPriceRatio(depositDetail.ethPriceAtDeposit, params.ethPrice);

            // Check the health is grater thsn 0.8
            if (borrowingHealth < 8000) revert IBorrowing.Borrow_BorrowHealthLow();

            // Calculate th borrower's debt
            uint256 borrowerDebt = calculateDebtAmount(depositDetail.normalizedAmount, params.lastCumulativeRate);
            uint128 downsideProtected = calculateDownsideProtected(
                depositDetail.depositedAmountInETH,
                params.ethPrice,
                depositDetail.ethPriceAtDeposit
            );

            // Check whether the Borrower have enough Trinty
            if (interfaces.usda.balanceOf(msg.sender) < borrowerDebt - downsideProtected) revert IBorrowing.Borrow_InsufficientBalance();

            // Update the borrower's data
            {
                depositDetail.ethPriceAtWithdraw = params.ethPrice;
                depositDetail.withdrawed = true;
                depositDetail.withdrawTime = params.withdrawTime;
                depositDetail.totalDebtAmountPaid = borrowerDebt - downsideProtected;

                uint256 discountedCollateral;

                // If the collateral is EtH, update ABOND USDA pool, since ETH only deposited in EXT protocol
                if (depositDetail.assetName == IBorrowing.AssetName.ETH) {
                    discountedCollateral = calculateDiscountedETH(
                        depositDetail.depositedAmount,
                        params.ethPrice > depositDetail.ethPriceAtDeposit
                            ? depositDetail.ethPriceAtDeposit
                            : params.ethPrice
                    ); // 0.4
                    omniChainData.abondUSDaPool += discountedCollateral;
                    interfaces.treasury.updateAbondUSDaPool(discountedCollateral,true);
                    // Mint the ABondTokens
                    depositDetail.aBondTokensAmount = mintAbondToken(
                        interfaces.abond,
                        params.bondRatio,
                        msg.sender,
                        params.index,
                        discountedCollateral
                    );
                } else {
                    discountedCollateral = 0;
                }

                // Calculate the USDa to burn
                uint256 burnValue = depositDetail.borrowedAmount - discountedCollateral;

                // Burn the USDa from the Borrower
                bool success = interfaces.usda.burnFromUser(msg.sender, burnValue);
                if (!success) revert IBorrowing.Borrow_BurnFailed();

                if (downsideProtected > 0) {
                    omniChainData.downsideProtected += downsideProtected;
                }

                //Transfer the remaining USDa to the treasury
                bool transfer = interfaces.usda.transferFrom(
                    msg.sender,
                    address(interfaces.treasury),
                    (borrowerDebt - depositDetail.borrowedAmount) + discountedCollateral
                );
                if (!transfer) revert IBorrowing.Borrow_USDaTransferFailed();

                //Update totalNormalizedAmount
                params.totalNormalizedAmount -= depositDetail.normalizedAmount;
                omniChainData.normalizedAmount -= depositDetail.normalizedAmount;

                //Update totalInterest
                omniChainData.totalInterest += borrowerDebt - depositDetail.borrowedAmount;
                interfaces.treasury.updateTotalInterest(borrowerDebt - depositDetail.borrowedAmount);

                // Update deposit details
                interfaces.treasury.updateDepositDetails(
                    msg.sender,
                    params.index,
                    depositDetail
                );
            }
            IBorrowing.CalculateCollateralToReturn_Result
                memory result = calculateCollateralToReturn(
                    IBorrowing.CalculateCollateralToReturn_Param(
                        interfaces.options,
                        depositDetail,
                        omniChainData,
                        borrowingHealth,
                        params.ethPrice,
                        params.collateralRemainingInWithdraw,
                        params.collateralValueRemainingInWithdraw
                    )
                );
            omniChainData = result.omniChainData;

            // update the global omnichain data
            if (interfaces.treasury.getTotalDeposited(msg.sender) == depositDetail.depositedAmountInETH) {
                --omniChainData.noOfBorrowers;
            }

            --omniChainData.totalNoOfDepositIndices;
            omniChainData.totalVolumeOfBorrowersAmountinWei -= depositDetail.depositedAmount;
            omniChainData.totalVolumeOfBorrowersAmountinUSD -= depositDetail.depositedAmountUsdValue;
            omniChainData.vaultValue -= depositDetail.depositedAmountUsdValue;

            // Update the individual collateral omnichain data
            --collateralData.noOfIndices;
            collateralData.totalDepositedAmount -= depositDetail.depositedAmount;
            collateralData.totalDepositedAmountInETH -= depositDetail.depositedAmountInETH;

            //Update the cumulative value in cds since, the cds amount is used to burn
            (omniChainData.cumulativeValue, omniChainData.cumulativeValueSign) = updateCumulativeValueInCDS(
                interfaces.globalVariables,
                interfaces.cds,
                params.ethPrice
            );

            // Update the updated individual collateral data and omnichain data in global variables
            interfaces.globalVariables.updateCollateralData(depositDetail.assetName, collateralData);
            interfaces.globalVariables.setOmniChainData(omniChainData);

            // Call withdraw in treasury
            bool sent = interfaces.treasury.withdraw(
                msg.sender,
                params.toAddress,
                result.collateralToReturn,
                params.exchangeRate,
                params.index
            );
            if (!sent) revert IBorrowing.Borrow_ETHTransferFailed();

            emit Withdraw(
                msg.sender,
                params.index,
                block.timestamp,
                result.collateralToReturn,
                depositDetail.aBondTokensAmount,
                borrowerDebt
            );

            return IBorrowing.BorrowWithdraw_Result(
                    downsideProtected,
                    params.totalNormalizedAmount,
                    result.collateralRemainingInWithdraw,
                    result.collateralValueRemainingInWithdraw
                );
        } else {
            revert IBorrowing.Borrow_AlreadyWithdrew();
        }
    }

    /**
     * @dev redeem abond yields
     * @param user abond holder address
     * @param aBondAmount redeeming abond amount
     * @param abondAddress abond token address
     * @param treasuryAddress treasury address
     * @param usdaAddress usda token address
     */
    function redeemYields(
        address user,
        uint128 aBondAmount,
        address usdaAddress,
        address abondAddress,
        address treasuryAddress,
        address borrow
    ) public returns (uint256) {
        // check abond amount is non zewro
        if (aBondAmount == 0) revert IBorrowing.Borrow_NeedsMoreThanZero();
        IABONDToken abond = IABONDToken(abondAddress);
        // get user abond state
        State memory userState = abond.userStates(user);
        // check user have enough abond
        if (aBondAmount > userState.aBondBalance) revert IBorrowing.Borrow_InsufficientBalance();

        ITreasury treasury = ITreasury(treasuryAddress);
        // calculate abond usda ratio
        uint128 usdaToAbondRatio = uint128((treasury.abondUSDaPool() * RATE_PRECISION) / abond.totalSupply());
        uint256 usdaToBurn = (usdaToAbondRatio * aBondAmount) / RATE_PRECISION;
        // update abondUsdaPool in treasury
        treasury.updateAbondUSDaPool(usdaToBurn, false);

        // calculate abond usda ratio from liquidation
        uint128 usdaToAbondRatioLiq = uint128((treasury.usdaGainedFromLiquidation() * RATE_PRECISION) /abond.totalSupply());
        uint256 usdaToTransfer = (usdaToAbondRatioLiq * aBondAmount) / RATE_PRECISION;
        //update usdaGainedFromLiquidation in treasury
        treasury.updateUSDaGainedFromLiquidation(usdaToTransfer, false);

        //Burn the usda from treasury
        treasury.approveTokens(
            IBorrowing.AssetName.USDa,
            borrow,
            (usdaToBurn + usdaToTransfer)
        );

        IUSDa usda = IUSDa(usdaAddress);
        // burn the usda
        bool burned = usda.contractBurnFrom(address(treasury), usdaToBurn);
        if (!burned) revert IBorrowing.Borrow_BurnFailed();

        if (usdaToTransfer > 0) {
            // transfer usda to user
            bool transferred = usda.contractTransferFrom(
                address(treasury),
                user,
                usdaToTransfer
            );
            if (!transferred) revert IBorrowing.Borrow_TransferFailed();
        }
        // withdraw eth from ext protocol
        uint256 withdrawAmount = treasury.withdrawFromExternalProtocol(user,aBondAmount);

        //Burn the abond from user
        bool success = abond.burnFromUser(msg.sender, aBondAmount);
        if (!success) revert IBorrowing.Borrow_BurnFailed();

        return withdrawAmount;
    }

    function _rpow(uint x, uint n, uint b) public pure returns (uint z) {
      assembly {
        switch x case 0 {switch n case 0 {z := b} default {z := 0}}
        default {
          switch mod(n, 2) case 0 { z := b } default { z := x }
          let half := div(b, 2)  // for rounding.
          for { n := div(n, 2) } n { n := div(n,2) } {
            let xx := mul(x, x)
            if iszero(eq(div(xx, x), x)) { revert(0,0) }
            let xxRound := add(xx, half)
            if lt(xxRound, xx) { revert(0,0) }
            x := div(xxRound, b)
            if mod(n,2) {
              let zx := mul(z, x)
              if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
              let zxRound := add(zx, half)
              if lt(zxRound, zx) { revert(0,0) }
              z := div(zxRound, b)
            }
          }
        }
      }
    }
}
