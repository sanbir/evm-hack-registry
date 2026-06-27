pragma solidity 0.8.20;

import {IFacadeInput} from "../../interfaces/oneClick/IFacadeInput.sol";
import {IFacadeOutput} from "../../interfaces/oneClick/IFacadeOutput.sol";
import {IOneClickProxy} from "../../interfaces/oneClick/IOneClickProxy.sol";
import {IMarginAccount} from "../../interfaces/IMarginAccount.sol";
import {ILiquidityPool} from "../../interfaces/ILiquidityPool.sol";
import {IFacadeTradeRouter} from "../../interfaces/oneClick/IFacadeTradeRouter.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract FacadeTradeRouter is AccessControl, IFacadeTradeRouter {

    bytes32 public constant ONE_CLICK_CONTRACT_ROLE = keccak256("ONE_CLICK_CONTRACT_ROLE");

    IFacadeInput facadeInput;
    IFacadeOutput facadeOutput;
    IOneClickProxy oneClickProxy;
    IMarginAccount marginAccount;
    address usdc;
    address weth;
    address wbtc;

    address[] tokens;

    struct FillSwapDataResult {
        IFacadeInput.SwapData[] calculateSwapsData;
        IFacadeOutput.SwapOutputData calculateSwapOutputData;
        uint calculateRepayAmount;
        bool fillBody;
    }

    constructor(
        address _facadeInput,
        address _facadeOutput,
        address _oneClickProxy,
        address _marginAccount,
        address _usdc,
        address _weth,
        address _wbtc
    ) {
        facadeInput = IFacadeInput(_facadeInput);
        facadeOutput = IFacadeOutput(_facadeOutput);
        oneClickProxy = IOneClickProxy(_oneClickProxy);
        marginAccount = IMarginAccount(_marginAccount);
        usdc = _usdc;
        weth = _weth;
        wbtc = _wbtc;
        tokens = [usdc, weth, wbtc];
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function increaseLongPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external onlyRole(ONE_CLICK_CONTRACT_ROLE) {
        facadeOutput.borrowSwapOutput(marginAccountID, token, usdc, token, amount);
    }

    function increaseShortPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external onlyRole(ONE_CLICK_CONTRACT_ROLE) {
        facadeInput.borrowSwapInput(marginAccountID, token, token, usdc, amount, 0);
    }

    function decreaseLongPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external onlyRole(ONE_CLICK_CONTRACT_ROLE) {
        (int256 positionSize,int256 collateralAmount, , bool isLong, bool isActive) = oneClickProxy.getPosition(marginAccountID, token);
        require(isActive, "Position does not exist");
        require(isLong, "Position is not long");
        require(amount <= uint(positionSize), "Amount exceeds position size");
        if (amount == uint(positionSize)) {
            _closeFullLongPosition(marginAccountID, token, amount, collateralAmount);
        } else {
            _closePartialLongPosition(marginAccountID, token, amount, collateralAmount);
        }
    }

    function _closePartialLongPosition(
        uint marginAccountID,
        address token,
        uint amount,
        int256 collateralAmount
    ) private {
        IFacadeInput.SwapData[] memory swapsData = new IFacadeInput.SwapData[](4);
        IFacadeOutput.SwapOutputData[] memory swapOutputData = new IFacadeOutput.SwapOutputData[](1);
        uint repayAmount = 0;
        uint collateralSize = convertToUint(collateralAmount);
        uint amountInUSDC = facadeInput.getAmountOut(token, usdc, amount);
        swapsData[0] = IFacadeInput.SwapData({
            tokenIn: token,
            amountIn: amount,
            amountOutMinimum: 0
        });

        if (collateralSize == 0) {
            repayAmount = type(uint).max;
        } else if (amountInUSDC >= collateralSize) {
            repayAmount = collateralSize;
        } else {
            repayAmount = amountInUSDC;
        }
        facadeInput.multiSwapInputRepay(marginAccountID, token, usdc, swapsData, swapOutputData, repayAmount);
    }

    function _closeFullLongPosition(
        uint marginAccountID,
        address token,
        uint amount,
        int256 collateralAmount
    ) private {
        IFacadeInput.SwapData[] memory swapsData = new IFacadeInput.SwapData[](4);
        IFacadeOutput.SwapOutputData[] memory swapOutputData = new IFacadeOutput.SwapOutputData[](1);
        uint repayAmount = 0;
        uint collateralSize = convertToUint(collateralAmount);
        uint amountOut = facadeInput.getAmountOut(token, usdc, amount);
        if (amountOut <= collateralSize) {
            uint leftAmount = collateralSize - amountOut;
            FillSwapDataResult memory fillSwapDataResult = fillSwapData(marginAccountID, usdc, leftAmount, 0);
            uint j = 1;
            for (uint i = 0; i < fillSwapDataResult.calculateSwapsData.length; i++) {
                if (fillSwapDataResult.calculateSwapsData[i].amountIn != 0) {
                    swapsData[j] = fillSwapDataResult.calculateSwapsData[i];
                    j++;
                }
            }
            swapsData[0] = IFacadeInput.SwapData({
                tokenIn: token,
                amountIn: amount,
                amountOutMinimum: 0
            });
            repayAmount += amountOut;
            swapOutputData[0] = fillSwapDataResult.calculateSwapOutputData;
            repayAmount += fillSwapDataResult.calculateRepayAmount;
        } else {
            swapsData[0] = IFacadeInput.SwapData({
                tokenIn: token,
                amountIn: amount,
                amountOutMinimum: 0
            });
            if (collateralSize == 0) {
                repayAmount = type(uint).max;
            } else {
                repayAmount = collateralSize;
            }
        }
        facadeInput.multiSwapInputRepay(marginAccountID, token, usdc, swapsData, swapOutputData, repayAmount);
    }

    function decreaseShortPosition(
        uint marginAccountID, 
        address token,
        uint amount
    ) external onlyRole(ONE_CLICK_CONTRACT_ROLE) {
        (int256 positionSize,int256 collateralAmount, , bool isLong, bool isActive) = oneClickProxy.getPosition(marginAccountID, token);
        require(isActive, "Position does not exist");
        require(!isLong, "Position is not short");
        require(amount <= convertToUint(positionSize), "Amount exceeds position size");
        if (amount == convertToUint(positionSize)) {
            _closeFullShortPosition(marginAccountID, token, positionSize, collateralAmount, amount);
        } else {
            _closePartialShortPosition(marginAccountID, token, amount, collateralAmount);
        }
    }

    function _closePartialShortPosition(
        uint marginAccountID,
        address token,
        uint amount,
        int256 collateralAmount
    ) private {
        IFacadeInput.SwapData[] memory swapsData = new IFacadeInput.SwapData[](4);
        IFacadeOutput.SwapOutputData[] memory swapOutputData = new IFacadeOutput.SwapOutputData[](2);
        uint repayAmount = 0;
        uint amountInUSDC = facadeOutput.getAmountIn(token, usdc, amount);
        uint collateralSize = convertToUint(collateralAmount);
        if (amountInUSDC <= collateralSize) {
            swapOutputData[0] = IFacadeOutput.SwapOutputData({
                tokenIn: usdc,
                amountOut: amount,
                amountInMaximum: amountInUSDC
            });
            repayAmount += amount;
        } else {
            uint balanceUSDCInToken;
            if (collateralSize != 0) {
                balanceUSDCInToken = facadeInput.getAmountOut(usdc, token, collateralSize);
            }
            uint leftAmount = amount - balanceUSDCInToken;
            FillSwapDataResult memory fillSwapDataResult = fillSwapData(marginAccountID, token, leftAmount, balanceUSDCInToken);
            uint j = 1;
            for (uint i = 0; i < fillSwapDataResult.calculateSwapsData.length; i++) {
                if (fillSwapDataResult.calculateSwapsData[i].amountIn != 0) {
                    swapsData[j] = fillSwapDataResult.calculateSwapsData[i];
                    j++;
                }
            }
            if (
                fillSwapDataResult.fillBody == false && 
                collateralAmount != 0
            ) {
                swapsData[0] = IFacadeInput.SwapData({
                    tokenIn: usdc,
                    amountIn: convertToUint(collateralAmount),
                    amountOutMinimum: balanceUSDCInToken
                });
                repayAmount += balanceUSDCInToken;
            }
            swapOutputData[0] = fillSwapDataResult.calculateSwapOutputData;
            repayAmount += fillSwapDataResult.calculateRepayAmount;
        }
        if (amount > repayAmount) {
            uint borrowAmount = facadeOutput.getAmountIn(token, usdc, amount - repayAmount);
            if (borrowAmount != 0) {
                oneClickProxy.borrow(marginAccountID, usdc, borrowAmount);
                swapOutputData[1] = IFacadeOutput.SwapOutputData({
                    tokenIn: usdc,
                    amountOut: amount - repayAmount,
                    amountInMaximum: borrowAmount
                });
                repayAmount += amount - repayAmount;
            }
        }
        facadeInput.multiSwapInputRepay(marginAccountID, token, token, swapsData, swapOutputData, repayAmount);
    }

    function _closeFullShortPosition(
        uint marginAccountID,
        address token,
        int256 positionSize,
        int256 collateralAmount,
        uint amount
    ) private {
        IFacadeInput.SwapData[] memory swapsData = new IFacadeInput.SwapData[](4);
        IFacadeOutput.SwapOutputData[] memory swapOutputData = new IFacadeOutput.SwapOutputData[](2);
        uint repayAmount = 0;
        uint amountOut = facadeInput.getAmountOut(usdc, token, uint(collateralAmount));
        if (amount >= amountOut) {
            if (collateralAmount == 0) {
                amountOut = 0;
            }
            uint leftAmount = convertToUint(positionSize) - amountOut;
            FillSwapDataResult memory fillSwapDataResult = fillSwapData(marginAccountID, token, leftAmount, amountOut);
            uint j = 1;
            for (uint i = 0; i < fillSwapDataResult.calculateSwapsData.length; i++) {
                if (fillSwapDataResult.calculateSwapsData[i].amountIn != 0) {
                    swapsData[j] = fillSwapDataResult.calculateSwapsData[i];
                    j++;
                }
            }
            if (
                fillSwapDataResult.fillBody == false && 
                collateralAmount != 0
            ) {
                swapsData[0] = IFacadeInput.SwapData({
                    tokenIn: usdc,
                    amountIn: convertToUint(collateralAmount),
                    amountOutMinimum: amountOut
                });
                repayAmount += amountOut;
            }
            swapOutputData[0] = fillSwapDataResult.calculateSwapOutputData;
            repayAmount += fillSwapDataResult.calculateRepayAmount;
        } else {
            uint swapAmount = facadeOutput.getAmountIn(token, usdc, amount);
            swapOutputData[0] = IFacadeOutput.SwapOutputData({
                tokenIn: usdc,
                amountOut: amount,
                amountInMaximum: swapAmount
            });
            repayAmount = amount;
        }

        if (convertToUint(positionSize) > repayAmount && swapsData[1].amountIn != 0) {
            uint borrowAmount = facadeOutput.getAmountIn(token, usdc, convertToUint(positionSize) - repayAmount);
            IFacadeInput.SwapData memory swapDataBody = swapsData[1];
            if (borrowAmount != 0) {
                oneClickProxy.borrow(marginAccountID, usdc, borrowAmount);
                swapsData[1] = IFacadeInput.SwapData({
                    tokenIn: usdc,
                    amountIn: borrowAmount + swapDataBody.amountIn,
                    amountOutMinimum: convertToUint(positionSize) - repayAmount + swapDataBody.amountOutMinimum
                });
                repayAmount += convertToUint(positionSize) - repayAmount;
            }
        }
        facadeInput.multiSwapInputRepay(marginAccountID, token, token, swapsData, swapOutputData, repayAmount);
    }

    function settlePositions(
        uint marginAccountID
    ) external onlyRole(ONE_CLICK_CONTRACT_ROLE) {
        for (uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint debt = ILiquidityPool(marginAccount.tokenToLiquidityPool(token)).getDebtWithAccruedInterest(marginAccountID);
            if (debt > 0) {
                FillSwapDataResult memory fillSwapDataResult = fillSwapData(marginAccountID, token, debt, 0);
                IFacadeOutput.SwapOutputData[] memory swapOutputData = new IFacadeOutput.SwapOutputData[](1);
                swapOutputData[0] = fillSwapDataResult.calculateSwapOutputData;
                facadeInput.multiSwapInputRepayForSettle(marginAccountID, token, fillSwapDataResult.calculateSwapsData, swapOutputData, fillSwapDataResult.calculateRepayAmount);
            }
        }
    }

    function fillSwapData(
        uint marginAccountID,
        address repayToken,
        uint leftAmount,
        uint amountOut
    ) internal returns (FillSwapDataResult memory) {
        IFacadeInput.SwapData[] memory swapsData = new IFacadeInput.SwapData[](3);
        IFacadeOutput.SwapOutputData memory swapOutputData;
        uint repayAmount = 0;
        bool fillBody = false;
        uint[3] memory margins = getMargin(marginAccountID);
        for (uint i = 0; i < tokens.length; i++) {
            if (leftAmount == 0) {
                break;
            }
            address token = tokens[i];
            if (margins[i] != 0) {
                if (token == repayToken) {
                    if (leftAmount <= margins[i]) {
                        repayAmount += leftAmount;
                        leftAmount = 0;
                    } else {
                        repayAmount += margins[i];
                        leftAmount -= margins[i];
                    }
                } else {
                    uint marginInRepayToken = facadeInput.getAmountOut(token, repayToken, margins[i]);
                    if (leftAmount <= marginInRepayToken) {
                        if (token == usdc && repayToken != usdc) {
                            leftAmount += amountOut;
                            fillBody = true;
                        }
                        uint marginAmount = facadeOutput.getAmountIn(repayToken, token, leftAmount);
                        swapOutputData = IFacadeOutput.SwapOutputData({
                            tokenIn: token,
                            amountOut: leftAmount,
                            amountInMaximum: marginAmount
                        });
                        repayAmount += leftAmount;
                        leftAmount = 0;
                    } else {
                        uint positionBodyAmount = 0;
                        uint addAmount = 0;
                        if (token == usdc && repayToken != usdc) {
                            positionBodyAmount = facadeOutput.getAmountIn(repayToken, token, amountOut);
                            addAmount = amountOut;
                            fillBody = true;
                        }
                        swapsData[i] = IFacadeInput.SwapData({
                            tokenIn: token,
                            amountIn: margins[i] + positionBodyAmount,
                            amountOutMinimum: marginInRepayToken + addAmount
                        });
                        repayAmount += marginInRepayToken + addAmount;
                        leftAmount -= marginInRepayToken;
                    }
                }
            }
        }

        return FillSwapDataResult({
            calculateSwapsData: swapsData,
            calculateSwapOutputData: swapOutputData,
            calculateRepayAmount: repayAmount,
            fillBody: fillBody
        });
    }

    function getMargin(
        uint marginAccountID
    ) public view returns (uint[3] memory) {
        uint balanceUsdc = marginAccount.getErc20ByContract(marginAccountID, usdc);
        uint balanceWeth = marginAccount.getErc20ByContract(marginAccountID, weth);
        uint balanceWbtc = marginAccount.getErc20ByContract(marginAccountID, wbtc);
        (int256 wethPositionSize, int256 wethCollateralAmount, , bool isLongWeth, bool isActiveWeth) = oneClickProxy.getPosition(marginAccountID, weth);
        (int256 wbtcPositionSize, int256 wbtcCollateralAmount, , bool isLongWbtc, bool isActiveWbtc) = oneClickProxy.getPosition(marginAccountID, wbtc);
        if (isActiveWeth) {
            if (isLongWeth) {
               balanceWeth -= uint(wethPositionSize);
            } else {
                balanceUsdc -= uint(wethCollateralAmount);
            }
        } 
        if (isActiveWbtc) {
            if (isLongWbtc) {
                balanceWbtc -= uint(wbtcPositionSize);
            } else {
                balanceUsdc -= uint(wbtcCollateralAmount);
            }
        }

        return [balanceUsdc, balanceWeth, balanceWbtc];
    }

    function convertToUint(
        int256 value
    ) internal pure returns (uint) {
        if (value < 0) {
            return uint(-value);
        } else {
            return uint(value);
        }
    }
}