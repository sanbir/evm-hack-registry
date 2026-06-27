// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.24;

import { DoughCore } from "../libraries/DoughCore.sol";
import { IPool } from "@aave/core-v3/contracts/interfaces/IPool.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { FlashLoanReceiverBase, IPoolAddressesProvider } from "@aave/core-v3/contracts/flashloan/base/FlashLoanReceiverBase.sol";
import { IDoughIndex, IDoughRealHF, IDoughDsa, IConnectorParaswapFlashloan, ILiquidationManager, CustomError} from "../Interfaces.sol";

/**
* $$$$$$$\                                $$\             $$$$$$$$\ $$\                                                   
* $$  __$$\                               $$ |            $$  _____|\__|                                                  
* $$ |  $$ | $$$$$$\  $$\   $$\  $$$$$$\  $$$$$$$\        $$ |      $$\ $$$$$$$\   $$$$$$\  $$$$$$$\   $$$$$$$\  $$$$$$\  
* $$ |  $$ |$$  __$$\ $$ |  $$ |$$  __$$\ $$  __$$\       $$$$$\    $$ |$$  __$$\  \____$$\ $$  __$$\ $$  _____|$$  __$$\ 
* $$ |  $$ |$$ /  $$ |$$ |  $$ |$$ /  $$ |$$ |  $$ |      $$  __|   $$ |$$ |  $$ | $$$$$$$ |$$ |  $$ |$$ /      $$$$$$$$ |
* $$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |$$  __$$ |$$ |  $$ |$$ |      $$   ____|
* $$$$$$$  |\$$$$$$  |\$$$$$$  |\$$$$$$$ |$$ |  $$ |      $$ |      $$ |$$ |  $$ |\$$$$$$$ |$$ |  $$ |\$$$$$$$\ \$$$$$$$\ 
* \_______/  \______/  \______/  \____$$ |\__|  \__|      \__|      \__|\__|  \__| \_______|\__|  \__| \_______| \_______|
*                               $$\   $$ |                                                                                
*                               \$$$$$$  |                                                                                
*                                \______/                                                                                 
* 
* @title ConnectorDeleverageParaswap
* @notice This connector is used deleverage DSA positions in Aave V3 with Flashloan and Paraswap
* @custom:version 1.0 - Initial release - Connector ID 22
* @author Liberalite https://github.com/liberalite
* @custom:coauthor 0xboga https://github.com/0xboga
*/
contract ConnectorDeleverageParaswap is FlashLoanReceiverBase {
    using SafeERC20 for IERC20;

    /* ========== LAYOUT ========== */
    address public dsaOwner;
    address public doughIndex;
    address public immutable doughRealHF;
    address public immutable liqManager;

    struct FlashloanVars {
        address dsaAddress;
        address srcToken;
        address destToken;
        address paraSwapContract;
        address tokenTransferProxy;
        uint256 srcAmount;
        uint256 destAmount;
        bool opt; // deloop 100% or in multiple steps
        bool sent;
        bytes paraswapCallData;
        bytes[] multiTokenSwapData;
        address[] debtTokens;
        address[] collateralTokens;
        uint256[] debtAmounts;
        uint256[] debtRateMode;
        uint256[] collateralAmounts;
    }

    struct FlashloanData {
        address[] debtTokens;
        address[] collateralTokens;
        uint256[] debtAmounts;
        uint256[] debtRateMode;
        uint256[] collateralAmounts;
    }

    /**
     * @notice Constructor to set the Dough Index, Dough Real HF and Liquidation Manager contract addresses
     * @param _doughIndex The address of the DoughIndex contract
     * @param _doughRealHF The address of the DoughRealHF contract
     * @param _liqManager The address of the LiquidationManager contract
     */
    constructor(address _doughIndex, address _doughRealHF, address _liqManager) FlashLoanReceiverBase(IPoolAddressesProvider(DoughCore.AAVE_V3_POOL_ADDRESS_PROVIDER)) {
        if (_doughIndex == address(0)) revert CustomError("invalid _doughIndex");
        if (_doughRealHF == address(0)) revert CustomError("invalid _doughRealHF");
        if (_liqManager == address(0)) revert CustomError("invalid _liqManager");
        doughIndex = _doughIndex;
        doughRealHF = _doughRealHF;
        liqManager = _liqManager;
    }

    function _getParaswapData(bytes memory _swapData) private pure returns (address, address, uint256, uint256, address, address, bytes memory) {
        // srcToken, destToken, srcAmount, destAmount, paraSwapContract, tokenTransferProxy, paraswapCallData
        return abi.decode(_swapData, (address, address, uint256, uint256, address, address, bytes));
    }

    // delegate Call
    function delegateDoughCall(uint256, address, uint256, bool _opt, bytes[] calldata _swapData) external {
        uint256 healthFactor = IDoughRealHF(doughRealHF).getDoughHFData(address(this));
        if (healthFactor > IDoughIndex(doughIndex).minDeleveragingRatio()) {
            bool isFlaggedForLiquidation = ILiquidationManager(liqManager).dsaLiquidationStatus(address(this));
            if(!isFlaggedForLiquidation) revert CustomError("Above minDeleveragingRatio");
        }
        deloopDebtPositions(_opt, _swapData);
    }

    function deloopDebtPositions (bool _opt, bytes[] memory _swapData) private {
        // get connectorFlashloan address
        address _connectorFlashloan = IDoughIndex(doughIndex).getDoughConnector(DoughCore.CONNECTOR_ID22);
        if (_connectorFlashloan == address(0)) revert CustomError("Unregistered Flashloan Connector");

        FlashloanData memory data;

        if(_opt) {
            (data.debtTokens, data.debtAmounts, data.debtRateMode, data.collateralTokens, data.collateralAmounts) = calculateCollateralAndDebtBeforeFlashLoanData();
            IConnectorParaswapFlashloan(_connectorFlashloan).flashloanReq(_opt, data.debtTokens, data.debtAmounts, data.debtRateMode, data.collateralTokens, data.collateralAmounts, _swapData);
        } else {
            (data.debtTokens, data.debtAmounts, data.debtRateMode, data.collateralTokens, data.collateralAmounts) = calculateCollateralAndDebtFromSwapData(_swapData);
            IConnectorParaswapFlashloan(_connectorFlashloan).flashloanReq(_opt, data.debtTokens, data.debtAmounts, data.debtRateMode, data.collateralTokens, data.collateralAmounts, _swapData);
        }
    }

    function flashloanReq(bool _opt, address[] memory debtTokens, uint256[] memory debtAmounts, uint256[] memory debtRateMode, address[] memory collateralTokens, uint256[] memory collateralAmounts, bytes[] memory swapData) external {
        bytes memory data = abi.encode(_opt, msg.sender, collateralTokens, collateralAmounts, swapData);
        IPool(address(POOL)).flashLoan(address(this), debtTokens, debtAmounts, debtRateMode, address(this), data, 0);
    }

    function calculateCollateralAndDebtBeforeFlashLoanData() private returns (address[] memory, uint256[] memory, uint256[] memory, address[] memory, uint256[] memory) {
        address[] memory whitelistedTokenList = IDoughIndex(doughIndex).getWhitelistedTokenList();
        uint256 length = whitelistedTokenList.length;

        address[] memory debtTokens = new address[](length);
        address[] memory collateralTokens = new address[](length);
        uint256[] memory collateralAmounts = new uint256[](length);
        uint256[] memory debtAmounts = new uint256[](length);
        uint256[] memory debtRateMode = new uint256[](length);

        uint256 actualAddedCollateral = 0;
        uint256 actualAdded = 0;

        for (uint256 i = 0; i < length;) {
            address tokenAddress = whitelistedTokenList[i];
            (uint256 currentATokenBalance, , uint256 currentVariableDebt, , , , , ,) = DoughCore._I_AAVE_V3_DATA_PROVIDER.getUserReserveData(tokenAddress, address(this));

            if (currentATokenBalance > 0) {
                if (currentVariableDebt > 0) {
                    if (currentATokenBalance >= currentVariableDebt) {
                        // Repay all debt with collateral
                        DoughCore.repayWithATokens(tokenAddress, currentVariableDebt);
                        IDoughIndex(doughIndex).updateBorrowDate(DoughCore.CONNECTOR_ID22, 0, address(this), tokenAddress);

                        uint256 remainingCollateral = currentATokenBalance - currentVariableDebt;
                        if (remainingCollateral > 0) {
                            // Leave 1 wei of collateral to avoid over-withdrawal
                            collateralTokens[actualAddedCollateral] = tokenAddress;
                            collateralAmounts[actualAddedCollateral] = remainingCollateral - 1;
                            actualAddedCollateral++;
                        }
                    } else {
                        // Partial repayment, remaining debt for flash loan
                        DoughCore.repayWithATokens(tokenAddress, currentATokenBalance);
                        uint256 remainingDebt = currentVariableDebt - currentATokenBalance;
                        debtTokens[actualAdded] = tokenAddress;
                        debtAmounts[actualAdded] = remainingDebt + 1; // Request 1 extra wei to ensure full repayment
                        debtRateMode[actualAdded] = DoughCore.FLASHLOAN_RATE_MODE;
                        actualAdded++;
                    }
                } else {
                    // No debt, track collateral
                    if (currentATokenBalance > 1) {
                        // Leave 1 wei of collateral to avoid over-withdrawal
                        collateralTokens[actualAddedCollateral] = tokenAddress;
                        collateralAmounts[actualAddedCollateral] = currentATokenBalance - 1;
                        actualAddedCollateral++;
                    }
                }
            } else if (currentVariableDebt > 0) {
                // No collateral, debt for flash loan
                debtTokens[actualAdded] = tokenAddress;
                debtAmounts[actualAdded] = currentVariableDebt + 1; // Request 1 extra wei to ensure full repayment
                debtRateMode[actualAdded] = DoughCore.FLASHLOAN_RATE_MODE;
                actualAdded++;
            }

            unchecked { i++; }
        }

        // Resize arrays to actual size
        assembly {
            mstore(debtTokens, actualAdded)
            mstore(debtAmounts, actualAdded)
            mstore(debtRateMode, actualAdded)
            mstore(collateralTokens, actualAddedCollateral)
            mstore(collateralAmounts, actualAddedCollateral)
        }

        return (debtTokens, debtAmounts, debtRateMode, collateralTokens, collateralAmounts);
    }

    function calculateCollateralAndDebtFromSwapData(bytes[] memory _swapData) private returns (address[] memory, uint256[] memory, uint256[] memory, address[] memory, uint256[] memory) {
        address[] memory whitelistedTokenList = IDoughIndex(doughIndex).getWhitelistedTokenList();
        uint256 length = whitelistedTokenList.length;

        repayWithCollateral(length, whitelistedTokenList);

        FlashloanVars memory flashloanVars;
        (flashloanVars.debtTokens, flashloanVars.debtAmounts, flashloanVars.debtRateMode, flashloanVars.collateralTokens, flashloanVars.collateralAmounts) = extractDeloopFromSwapData(_swapData);

        return (flashloanVars.debtTokens, flashloanVars.debtAmounts, flashloanVars.debtRateMode, flashloanVars.collateralTokens, flashloanVars.collateralAmounts);
    }

    function extractDeloopFromSwapData(bytes[] memory _swapData) private pure returns (address[] memory, uint256[] memory, uint256[] memory, address[] memory, uint256[] memory) {
        uint256 length = _swapData.length;
        
        address[] memory debtTokens = new address[](length);
        uint256[] memory debtAmounts = new uint256[](length);
        uint256[] memory debtRateMode = new uint256[](length);
        address[] memory collateralTokens = new address[](length);
        uint256[] memory collateralAmounts = new uint256[](length);
        
        uint256 actualAdded = 0;

        FlashloanVars memory flashloanVars;
        for (uint i = 0; i < _swapData.length;) {
            (flashloanVars.srcToken, flashloanVars.destToken, flashloanVars.srcAmount, flashloanVars.destAmount,,,) = _getParaswapData(_swapData[i]);
            debtTokens[actualAdded] = flashloanVars.destToken;
            debtAmounts[actualAdded] = flashloanVars.destAmount - (flashloanVars.destAmount / 1000); // Request 1 extra wei to ensure full repayment
            debtRateMode[actualAdded] = DoughCore.FLASHLOAN_RATE_MODE;
            collateralTokens[actualAdded] = flashloanVars.srcToken;
            collateralAmounts[actualAdded] = flashloanVars.srcAmount; // add 10% buffer for slippage
            actualAdded++;
            unchecked { i++; }
        }

        // Resize arrays to actual size
        assembly {
            mstore(debtTokens, actualAdded)
            mstore(debtAmounts, actualAdded)
            mstore(debtRateMode, actualAdded)
            mstore(collateralTokens, actualAdded)
            mstore(collateralAmounts, actualAdded)
        }

        return (debtTokens, debtAmounts, debtRateMode, collateralTokens, collateralAmounts);
    }

    function repayWithCollateral(uint256 length, address[] memory whitelistedTokenList) private {
        for (uint256 i = 0; i < length;) {
            address tokenAddress = whitelistedTokenList[i];
            (uint256 currentATokenBalance, , uint256 currentVariableDebt, , , , , ,) = DoughCore._I_AAVE_V3_DATA_PROVIDER.getUserReserveData(tokenAddress, address(this));

            if (currentATokenBalance > 0) {
                if (currentVariableDebt > 0) {
                    if (currentATokenBalance >= currentVariableDebt) {
                        // Repay all debt with collateral
                        DoughCore.repayWithATokens(tokenAddress, currentVariableDebt);
                        IDoughIndex(doughIndex).updateBorrowDate(DoughCore.CONNECTOR_ID22, 0, address(this), tokenAddress);
                    } else {
                        // Partial repayment, remaining debt for flash loan
                        DoughCore.repayWithATokens(tokenAddress, currentATokenBalance);
                    }
                }
            }

            unchecked { i++; }
        }
    }

    function executeOperation(address[] memory assets, uint256[] memory amounts, uint256[] memory premiums, address initiator, bytes calldata data) external override returns (bool) {
        if (initiator != address(this)) revert CustomError("not-same-sender");
        if (msg.sender != address(POOL)) revert CustomError("not-aave-sender");

        FlashloanVars memory flashloanVars;
        (flashloanVars.opt, flashloanVars.dsaAddress, flashloanVars.collateralTokens, flashloanVars.collateralAmounts, flashloanVars.multiTokenSwapData) = abi.decode(data, (bool, address, address[], uint256[], bytes[]));

        deloopInOneOrMultipleTransactions(flashloanVars.opt, flashloanVars.dsaAddress, assets, amounts, premiums, flashloanVars.collateralTokens, flashloanVars.collateralAmounts, flashloanVars.multiTokenSwapData);

        return true;
    }

    function deloopInOneOrMultipleTransactions(bool opt, address _dsaAddress, address[] memory assets, uint256[] memory amounts, uint256[] memory premiums, address[] memory collateralTokens, uint256[] memory collateralAmounts, bytes[] memory multiTokenSwapData) private {
        // Repay all flashloan assets or withdraw all collaterals
        repayAllDebtAssetsWithFlashLoan(opt, _dsaAddress, assets, amounts);

        // Extract all collaterals
        extractAllCollaterals(_dsaAddress, collateralTokens, collateralAmounts); 

        // Deloop all collaterals
        deloopAllCollaterals(multiTokenSwapData);

        // Repay all flashloan assets or withdraw all collaterals
        repayFlashloansAndTransferToTreasury(opt, _dsaAddress, assets, amounts, premiums);
    }

    function repayFlashloansAndTransferToTreasury(bool opt, address _dsaAddress, address[] memory assets, uint256[] memory amounts, uint256[] memory premiums) private {
        address[] memory whitelistedTokenList = IDoughIndex(doughIndex).getWhitelistedTokenList();
        address treasury = IDoughIndex(doughIndex).treasury();

        for (uint i = 0; i < whitelistedTokenList.length; i++) {
            address token = whitelistedTokenList[i];
            uint256 balance = IERC20(token).balanceOf(address(this));

            if (balance > 0) {
                // Initialize the transfer amount to the full balance
                uint256 transferAmount = balance;

                // Look through the assets to check if this token was involved in a flash loan
                for (uint j = 0; j < assets.length; j++) {
                    if (token == assets[j]) {
                        uint256 repaymentTotal = amounts[j] + premiums[j];
                        if (balance >= repaymentTotal) {
                            transferAmount = balance - repaymentTotal;
                        }
                        IERC20(token).safeIncreaseAllowance(address(POOL), repaymentTotal);
                        break;  // Break once the token is found in the assets array
                    }
                }

                // Perform the transfer if there is any amount to transfer
                if (transferAmount > 0) {
                    if(opt) {
                        // Transfer to treasury
                        IERC20(token).safeTransfer(treasury, transferAmount);
                    } else {
                        // Supply to AaveV3
                        IERC20(token).safeIncreaseAllowance(DoughCore.AAVE_V3_POOL_ADDRESS, transferAmount);
                        DoughCore._I_AAVE_V3_POOL.supply(token, transferAmount, _dsaAddress, 0);
                    }
                }
            }
        }
    }

    function extractAllCollaterals(address dsaAddress, address[] memory collateralTokens, uint256[] memory collateralAmounts) private {
        // Repay all asset flash loan
        for (uint i = 0; i < collateralTokens.length;) {
            IDoughDsa(dsaAddress).executeAction(DoughCore.CONNECTOR_ID22, collateralTokens[i], 0, collateralTokens[i], collateralAmounts[i], 1);
            IERC20(collateralTokens[i]).safeTransferFrom(dsaAddress, address(this), collateralAmounts[i]);
            unchecked { i++; }
        }
    }

    function deloopAllCollaterals(bytes[] memory multiTokenSwapData) private {        
        FlashloanVars memory flashloanVars;

        for (uint i = 0; i < multiTokenSwapData.length;) {
            // Deloop
            (flashloanVars.srcToken, flashloanVars.destToken, flashloanVars.srcAmount, flashloanVars.destAmount, flashloanVars.paraSwapContract, flashloanVars.tokenTransferProxy, flashloanVars.paraswapCallData) = _getParaswapData(multiTokenSwapData[i]);

            // using ParaSwap
            IERC20(flashloanVars.srcToken).safeIncreaseAllowance(flashloanVars.tokenTransferProxy, flashloanVars.srcAmount);
            (flashloanVars.sent, ) = flashloanVars.paraSwapContract.call(flashloanVars.paraswapCallData);
            if (!flashloanVars.sent) revert CustomError("ParaSwap deloop failed");

            unchecked { i++; }
        }
    }

    function repayAllDebtAssetsWithFlashLoan(bool opt, address dsaAddress, address[] memory assets, uint256[] memory amounts) private {
        for (uint i = 0; i < assets.length;) {
            IERC20(assets[i]).safeIncreaseAllowance(dsaAddress, amounts[i]);
            IDoughDsa(dsaAddress).executeAction(DoughCore.CONNECTOR_ID22, assets[i], amounts[i], assets[i], 0, 1);
            if(opt) IDoughIndex(doughIndex).updateBorrowDate(DoughCore.CONNECTOR_ID22, 0, dsaAddress, assets[i]);
            unchecked { i++; }
        }
    }

    /**
     * @notice Function to set new dough index address after upgrade
     * @param _newDoughIndex The address of the new DoughIndex contract
     * @dev The new DoughIndex address should not be the zero address
     * @dev Only the multisig of DoughIndex can call this function
     */
    function setNewDoughIndex(address _newDoughIndex) external {
        if (msg.sender != IDoughIndex(doughIndex).multisig()) revert CustomError("not multisig of doughIndex");
        if (_newDoughIndex == address(0)) revert CustomError("invalid _newDoughIndex");
        doughIndex = _newDoughIndex;
    }

    /** @notice Function to get the Dough Multisig address */
    function getDoughMultisig() external view returns (address) {
        return IDoughIndex(doughIndex).multisig();
    }

    /** @notice Function to get the Dough Index address */
    function getDoughIndex() external view returns (address) {
        return doughIndex;
    }

    /**
    * @notice Function to withdraw accidentaly sent ETH/ERC20 tokens to the connector
    * @param _asset The address of the ETH/ERC20 token
    * @param _treasury The address of the treasury
    * @param _amount The amount of ETH/ERC20 token to withdraw
    */
    function withdrawToken(address _asset, address _treasury, uint256 _amount) external {
        if (msg.sender != IDoughIndex(doughIndex).multisig()) revert CustomError("not multisig of doughIndex");
        if (_treasury == address(0)) revert CustomError("invalid _treasury");
        if (_amount == 0) revert CustomError("must be greater than zero");
        if (_asset == DoughCore.ETH) {
            payable(_treasury).transfer(_amount);
        } else {
            uint256 balanceOfToken = IERC20(_asset).balanceOf(address(this));
            uint256 transferAmount = _amount;
            if (_amount > balanceOfToken) {
                transferAmount = balanceOfToken;
            }
            IERC20(_asset).safeTransfer(_treasury, transferAmount);
        }
    }

}