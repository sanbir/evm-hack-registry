// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "../storage/PerpStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/metatx/ERC2771Context.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

abstract contract PerpConfig is PerpStorage, AccessControl, ERC2771Context {
    
    // --- Events ---

    event ParametersUpdated(
        address _oracle,
        uint256 _feeFrontend,
        address _feeProtocolAddr,
        uint256 _insuranceFundCap,
        uint256 _maxLeverage,
        uint256 _liquidationDiscount
    );

    event LockedParameterUpdate(  
        uint256 paramLockedUntil,      
        uint256 _MMR,
        uint256 _tradingFee,
        uint256 _flatTradingFee,
        uint256 _feeLP,
        uint256 _liquidityMinFee,
        uint256 _liquidityMaxFee,
        uint256 _liquidityFeeK,
        uint256 _fundingC,
        UtilMath.ClampParameters _clampParams,
        uint256 _paramTimeLock,
        uint256 _minimumTradeSize
    );

    // --- External Functions (Admin Only) ---

    ///@dev Only callable by mod users. Prepares the function setTimeLockedParameters to be called with the same parameters after paramTimeLock time.
    ///@param _MMR margin ratio threshold under which you can be partially liquidated
    ///@param _tradingFee percentage of the trade size that goes into fees
    ///@param _flatTradingFee flat trading fee on each trade
    ///@param _feeLP fraction of the trading fees that goes to LPs 
    ///@param _liquidityMinFee minimum liquidity fee allowed
    ///@param _liquidityMaxFee maximum liquidity fee allowed
    ///@param _liquidityFeeK K parameter of the liquidity fee formula
    ///@param _fundingC C parameter of the funding rate formula
    ///@param _clampParams parameters of the funding rate clamp function
    ///@param _paramTimeLock time lock duration for setting parameters
    ///@param _minimumTradeSize minimum trade size allowed in openTrade.
    function prepareTimeLockedParameters(
        uint256 _MMR,
        uint256 _tradingFee,
        uint256 _flatTradingFee,
        uint256 _feeLP,
        uint256 _liquidityMinFee,
        uint256 _liquidityMaxFee,
        uint256 _liquidityFeeK,
        uint256 _fundingC,
        UtilMath.ClampParameters memory _clampParams,
        uint256 _paramTimeLock,
        uint256 _minimumTradeSize
    )
    external
    onlyRole(MOD_ROLE)
    {
        require(
            _MMR < 1e6 &&
            _clampParams.minFR <= _clampParams.maxFR &&
            _feeLP <= decimals.feeFractionsDecimals - feeFrontend &&
            _tradingFee < decimals.tradingFeeDecimals &&
            _flatTradingFee*1e18 < (decimals.tradingFeeDecimals - _tradingFee)*_minimumTradeSize &&
            _liquidityMinFee <= _liquidityMaxFee && 
            _liquidityMaxFee <= 1e10
            , "C"
        );
        paramLockedUntil = block.timestamp + paramTimeLock;
        paramHash = keccak256(
            abi.encode(
                keccak256(
                    abi.encodePacked(
                    _MMR, 
                    _tradingFee, 
                    _flatTradingFee, 
                    _feeLP)
                ),
                _liquidityMinFee,
                _liquidityMaxFee,
                _liquidityFeeK,
                _fundingC,
                _clampParams,
                _paramTimeLock,
                _minimumTradeSize
        ));
        emit LockedParameterUpdate(paramLockedUntil, _MMR, _tradingFee, _flatTradingFee, _feeLP, _liquidityMinFee, _liquidityMaxFee, _liquidityFeeK, _fundingC, _clampParams, _paramTimeLock, _minimumTradeSize);
    }

    ///@dev Only callable by mod users. Sets parameters in the contract.
    ///@param _MMR margin ratio threshold under which you can be partially liquidated
    ///@param _tradingFee percentage of the trade size that goes into fees
    ///@param _flatTradingFee flat trading fee on each trade
    ///@param _feeLP fraction of the trading fees that goes to LPs 
    ///@param _liquidityMinFee minimum liquidity fee allowed
    ///@param _liquidityMaxFee maximum liquidity fee allowed
    ///@param _liquidityFeeK K parameter of the liquidity fee formula
    ///@param _fundingC C parameter of the funding rate formula
    ///@param _clampParams parameters of the funding rate clamp function
    ///@param _paramTimeLock time lock duration for setting parameters
    ///@param _minimumTradeSize minimum trade size allowed in openTrade.
    function setTimeLockedParameters(
        uint256 _MMR,
        uint256 _tradingFee,
        uint256 _flatTradingFee,
        uint256 _feeLP,
        uint256 _liquidityMinFee,
        uint256 _liquidityMaxFee,
        uint256 _liquidityFeeK,
        uint256 _fundingC,
        UtilMath.ClampParameters memory _clampParams,
        uint256 _paramTimeLock,
        uint256 _minimumTradeSize
    )
    external
    onlyRole(MOD_ROLE)
    {
        bytes32 newParamHash = keccak256(
            abi.encode(
                keccak256(
                    abi.encodePacked(
                    _MMR, 
                    _tradingFee, 
                    _flatTradingFee, 
                    _feeLP)
                ),
                _liquidityMinFee,
                _liquidityMaxFee,
                _liquidityFeeK,
                _fundingC,
                _clampParams,
                _paramTimeLock,
                _minimumTradeSize
        ));
        require(block.timestamp >= paramLockedUntil && newParamHash == paramHash, "C");
        

        MMR = _MMR;
        feeLP = _feeLP;
        flatTradingFee = _flatTradingFee;
        tradingFee = _tradingFee;
        liquidityMinFee = _liquidityMinFee;
        liquidityMaxFee = _liquidityMaxFee;
        liquidityFeeK = _liquidityFeeK;
        fundingC = _fundingC;
        clampParameters = _clampParams;
        paramTimeLock = _paramTimeLock;
        minimumTradeSize = _minimumTradeSize;
    }

    ///@dev Only callable by mod users. Sets parameters in the contract.
    ///@param _oracle address of the oracle contract.
    ///@param _feeFrontend  percentage of the fee that goes to the frontend address
    ///@param _feeProtocolAddr address that collects the protocol fees
    ///@param _insuranceFundCap cap for the insurance fund
    ///@param _maxLeverage maximum leverage allowed in trades.
    ///@param _liquidationDiscount discount for the liquidator during liquidations
    ///@param _maxLpLeverage maximum leverage allowed to LPs
    function setUnguardedParameters(
        address _oracle,
        uint32 _feeFrontend,
        address _feeProtocolAddr,
        uint256 _insuranceFundCap,
        uint8 _maxLeverage,
        uint32 _liquidationDiscount,
        uint8 _maxLpLeverage, 
        uint8 _slipLiquidationTh
    )
    external
    onlyRole(MOD_ROLE)
    {
        require(
            _oracle != address(0) &&
            _feeFrontend <= decimals.feeFractionsDecimals - feeLP &&
            _liquidationDiscount < 1e6/2 &&
            feeProtocolAddr != address(0)
            , "C");
        oracle = _oracle;
        insuranceFundCap = _insuranceFundCap;
        feeFrontend = _feeFrontend;
        feeProtocolAddr = _feeProtocolAddr;
        liquidationDiscount = _liquidationDiscount;
        maxLeverage = _maxLeverage; 
        maxLpLeverage = _maxLpLeverage;
        slipLiquidationTh = _slipLiquidationTh;  
        emit ParametersUpdated(_oracle, _feeFrontend, _feeProtocolAddr, _insuranceFundCap, _maxLeverage, _liquidationDiscount);   
    }



    function _msgSender() internal view override(Context, ERC2771Context) returns (address sender) {
        return ERC2771Context._msgSender();
    }

    function _msgData() internal view override(Context, ERC2771Context) returns (bytes calldata) {
        return ERC2771Context._msgData();
    }

    function _contextSuffixLength() internal view virtual override(Context, ERC2771Context) returns (uint256) {
        return ERC2771Context._contextSuffixLength();
    }
}