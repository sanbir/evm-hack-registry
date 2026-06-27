// https://peapods.finance

// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import '@uniswap/v3-core/contracts/libraries/FixedPoint96.sol';
import './interfaces/IERC20Metadata.sol';
import './interfaces/IUniswapV2Pair.sol';
import './interfaces/IV3TwapUtilities.sol';
import './DecentralizedIndex.sol';

contract WeightedIndex is DecentralizedIndex {
  using SafeERC20 for IERC20;

  IUniswapV2Factory immutable V2_FACTORY;

  uint256 _totalWeights;

  constructor(
    string memory _name,
    string memory _symbol,
    uint256 _bondFee,
    uint256 _debondFee,
    address[] memory _tokens,
    uint256[] memory _weights,
    address _lpRewardsToken,
    address _v2Router,
    address _dai,
    bool _stakeRestriction,
    IV3TwapUtilities _v3TwapUtilities
  )
    DecentralizedIndex(
      _name,
      _symbol,
      _bondFee,
      _debondFee,
      _lpRewardsToken,
      _v2Router,
      _dai,
      _stakeRestriction,
      _v3TwapUtilities
    )
  {
    indexType = IndexType.WEIGHTED;
    V2_FACTORY = IUniswapV2Factory(IUniswapV2Router02(_v2Router).factory());
    require(_tokens.length == _weights.length, 'INIT');
    for (uint256 _i; _i < _tokens.length; _i++) {
      indexTokens.push(
        IndexAssetInfo({
          token: _tokens[_i],
          basePriceUSDX96: 0,
          weighting: _weights[_i],
          c1: address(0),
          q1: 0 // amountsPerIdxTokenX96
        })
      );
      _totalWeights += _weights[_i];
      _fundTokenIdx[_tokens[_i]] = _i;
      _isTokenInIndex[_tokens[_i]] = true;
    }
    // at idx == 0, need to find X in [1/X = tokenWeightAtIdx/totalWeights]
    // at idx > 0, need to find Y in (Y/X = tokenWeightAtIdx/totalWeights)
    uint256 _xX96 = (FixedPoint96.Q96 * _totalWeights) / _weights[0];
    for (uint256 _i; _i < _tokens.length; _i++) {
      indexTokens[_i].q1 =
        (_weights[_i] * _xX96 * 10 ** IERC20Metadata(_tokens[_i]).decimals()) /
        _totalWeights;
    }
  }

  function _getNativePriceUSDX96() internal view returns (uint256) {
    IUniswapV2Pair _nativeStablePool = IUniswapV2Pair(
      V2_FACTORY.getPair(DAI, WETH)
    );
    address _token0 = _nativeStablePool.token0();
    (uint8 _decimals0, uint8 _decimals1) = (
      IERC20Metadata(_token0).decimals(),
      IERC20Metadata(_nativeStablePool.token1()).decimals()
    );
    (uint112 _res0, uint112 _res1, ) = _nativeStablePool.getReserves();
    return
      _token0 == DAI
        ? (FixedPoint96.Q96 * _res0 * 10 ** _decimals1) /
          _res1 /
          10 ** _decimals0
        : (FixedPoint96.Q96 * _res1 * 10 ** _decimals0) /
          _res0 /
          10 ** _decimals1;
  }

  function _getTokenPriceUSDX96(
    address _token
  ) internal view returns (uint256) {
    if (_token == WETH) {
      return _getNativePriceUSDX96();
    }
    IUniswapV2Pair _pool = IUniswapV2Pair(V2_FACTORY.getPair(_token, WETH));
    address _token0 = _pool.token0();
    uint8 _decimals0 = IERC20Metadata(_token0).decimals();
    uint8 _decimals1 = IERC20Metadata(_pool.token1()).decimals();
    (uint112 _res0, uint112 _res1, ) = _pool.getReserves();
    uint256 _nativePriceUSDX96 = _getNativePriceUSDX96();
    return
      _token0 == WETH
        ? (_nativePriceUSDX96 * _res0 * 10 ** _decimals1) /
          _res1 /
          10 ** _decimals0
        : (_nativePriceUSDX96 * _res1 * 10 ** _decimals0) /
          _res0 /
          10 ** _decimals1;
  }

  function bond(address _token, uint256 _amount) external override noSwap {
    require(_isTokenInIndex[_token], 'INVALIDTOKEN');
    uint256 _tokenIdx = _fundTokenIdx[_token];
    uint256 _tokensMinted = (_amount * FixedPoint96.Q96 * 10 ** decimals()) /
      indexTokens[_tokenIdx].q1;
    uint256 _feeTokens = _isFirstIn() ? 0 : (_tokensMinted * BOND_FEE) / 10000;
    _mint(_msgSender(), _tokensMinted - _feeTokens);
    if (_feeTokens > 0) {
      _mint(address(this), _feeTokens);
    }
    for (uint256 _i; _i < indexTokens.length; _i++) {
      uint256 _transferAmount = _i == _tokenIdx
        ? _amount
        : (_amount *
          indexTokens[_i].weighting *
          10 ** IERC20Metadata(indexTokens[_i].token).decimals()) /
          indexTokens[_tokenIdx].weighting /
          10 ** IERC20Metadata(_token).decimals();
      _transferAndValidate(
        IERC20(indexTokens[_i].token),
        _msgSender(),
        _transferAmount
      );
    }
    emit Bond(_msgSender(), _token, _amount, _tokensMinted);
  }

  function debond(
    uint256 _amount,
    address[] memory,
    uint8[] memory
  ) external override noSwap {
    uint256 _amountAfterFee = _isLastOut(_amount)
      ? _amount
      : (_amount * (10000 - DEBOND_FEE)) / 10000;
    uint256 _percAfterFeeX96 = (_amountAfterFee * FixedPoint96.Q96) /
      totalSupply();
    _transfer(_msgSender(), address(this), _amount);
    _burn(address(this), _amountAfterFee);
    for (uint256 _i; _i < indexTokens.length; _i++) {
      uint256 _tokenSupply = IERC20(indexTokens[_i].token).balanceOf(
        address(this)
      );
      uint256 _debondAmount = (_tokenSupply * _percAfterFeeX96) /
        FixedPoint96.Q96;
      IERC20(indexTokens[_i].token).safeTransfer(_msgSender(), _debondAmount);
      require(
        IERC20(indexTokens[_i].token).balanceOf(address(this)) >=
          _tokenSupply - _debondAmount,
        'HEAVY'
      );
    }
    emit Debond(_msgSender(), _amount);
  }

  function getTokenPriceUSDX96(
    address _token
  ) external view override returns (uint256) {
    return _getTokenPriceUSDX96(_token);
  }

  function getIdxPriceUSDX96() public view override returns (uint256, uint256) {
    uint256 _priceX96;
    uint256 _X96_2 = 2 ** (96 / 2);
    for (uint256 _i; _i < indexTokens.length; _i++) {
      uint256 _tokenPriceUSDX96_2 = _getTokenPriceUSDX96(
        indexTokens[_i].token
      ) / _X96_2;
      _priceX96 +=
        (_tokenPriceUSDX96_2 * indexTokens[_i].q1) /
        10 ** IERC20Metadata(indexTokens[_i].token).decimals() /
        _X96_2;
    }
    return (0, _priceX96);
  }
}
