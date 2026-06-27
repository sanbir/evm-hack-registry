// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IDecentralizedIndex is IERC20 {
  enum IndexType {
    WEIGHTED,
    UNWEIGHTED
  }

  struct IndexAssetInfo {
    address token;
    uint256 weighting;
    uint256 basePriceUSDX96;
    address c1; // arbitrary contract/address field we can use for an index
    uint256 q1; // arbitrary quantity/number field we can use for an index
  }

  event Create(address indexed newIdx, address indexed wallet);
  event Bond(
    address indexed wallet,
    address indexed token,
    uint256 amountTokensBonded,
    uint256 amountTokensMinted
  );
  event Debond(address indexed wallet, uint256 amountDebonded);
  event AddLiquidity(
    address indexed wallet,
    uint256 amountTokens,
    uint256 amountDAI
  );
  event RemoveLiquidity(address indexed wallet, uint256 amountLiquidity);

  function FLASH_FEE_DAI() external view returns (uint256);

  function BOND_FEE() external view returns (uint256); // 1 == 0.01%, 10 == 0.1%, 100 == 1%

  function DEBOND_FEE() external view returns (uint256); // 1 == 0.01%, 10 == 0.1%, 100 == 1%

  function indexType() external view returns (IndexType);

  function created() external view returns (uint256);

  function lpStakingPool() external view returns (address);

  function lpRewardsToken() external view returns (address);

  function getIdxPriceUSDX96() external view returns (uint256, uint256);

  function isAsset(address token) external view returns (bool);

  function getAllAssets() external view returns (IndexAssetInfo[] memory);

  function getTokenPriceUSDX96(address token) external view returns (uint256);

  function bond(address token, uint256 amount) external;

  function debond(
    uint256 amount,
    address[] memory token,
    uint8[] memory percentage
  ) external;

  function addLiquidityV2(
    uint256 idxTokens,
    uint256 daiTokens,
    uint256 slippage
  ) external;

  function removeLiquidityV2(
    uint256 lpTokens,
    uint256 minTokens,
    uint256 minDAI
  ) external;

  function flash(
    address recipient,
    address token,
    uint256 amount,
    bytes calldata data
  ) external;
}
