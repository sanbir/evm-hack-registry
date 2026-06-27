// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface ILiquidXv2Router01 {
  function factory() external view returns (address);
  function WETH() external view returns (address);

  function addLiquidity(
    address tokenA,
    address tokenB,
    uint amountADesired,
    uint amountBDesired,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  ) external returns (uint amountA, uint amountB, uint liquidity);
  function addLiquidityETH(
    address token,
    uint amountTokenDesired,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline
  ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
  function removeLiquidity(
    address tokenA,
    address tokenB,
    uint liquidity,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  ) external returns (uint amountA, uint amountB);
  function removeLiquidityETH(
    address token,
    uint liquidity,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline
  ) external returns (uint amountToken, uint amountETH);
  function removeLiquidityWithPermit(
    address tokenA,
    address tokenB,
    uint liquidity,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline,
    bool approveMax, uint8 v, bytes32 r, bytes32 s
  ) external returns (uint amountA, uint amountB);
  function removeLiquidityETHWithPermit(
    address token,
    uint liquidity,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline,
    bool approveMax, uint8 v, bytes32 r, bytes32 s
  ) external returns (uint amountToken, uint amountETH);
  function swapExactTokensForTokens(
    uint amountIn,
    uint amountOutMin,
    address[] calldata path,
    address to,
    uint deadline
  ) external returns (uint[] memory amounts);
  function swapTokensForExactTokens(
    uint amountOut,
    uint amountInMax,
    address[] calldata path,
    address to,
    uint deadline
  ) external returns (uint[] memory amounts);
  function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);
  function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
    external
    returns (uint[] memory amounts);
  function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    returns (uint[] memory amounts);
  function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);

  function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
  function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
  function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) external pure returns (uint amountIn);
  function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
  function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IRewarderv2 {
  function getReward(address account, address token) external view returns(uint256);
  function claim(address account, address token) external;
}

interface ILiquidXv2Factory {
  function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface ILiquidXv2Pair {
  function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IERC20 {
  event Approval(address indexed owner, address indexed spender, uint value);
  event Transfer(address indexed from, address indexed to, uint value);

  function name() external view returns (string memory);
  function symbol() external view returns (string memory);
  function decimals() external view returns (uint8);
  function totalSupply() external view returns (uint);
  function balanceOf(address owner) external view returns (uint);
  function allowance(address owner, address spender) external view returns (uint);

  function approve(address spender, uint value) external returns (bool);
  function transfer(address to, uint value) external returns (bool);
  function transferFrom(address from, address to, uint value) external returns (bool);
}

interface IWETH {
  function deposit() external payable;
  function transfer(address to, uint value) external returns (bool);
  function withdraw(uint) external;
}

interface IERC20Mint is IERC20 {
  function mint(address account, uint256 amount) external;
  function burn(address account, uint256 amount) external;
}

interface IERC20Permit {
  function permit(
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external;
  function nonces(address owner) external view returns (uint256);
  function DOMAIN_SEPARATOR() external view returns (bytes32);
}

library Address {
  function isContract(address account) internal view returns (bool) {
    return account.code.length > 0;
  }

  function sendValue(address payable recipient, uint256 amount) internal {
    require(address(this).balance >= amount, "Address: insufficient balance");

    (bool success, ) = recipient.call{value: amount}("");
    require(success, "Address: unable to send value, recipient may have reverted");
  }

  function functionCall(address target, bytes memory data) internal returns (bytes memory) {
      return functionCallWithValue(target, data, 0, "Address: low-level call failed");
  }

  function functionCall(
      address target,
      bytes memory data,
      string memory errorMessage
  ) internal returns (bytes memory) {
      return functionCallWithValue(target, data, 0, errorMessage);
  }

  function functionCallWithValue(
      address target,
      bytes memory data,
      uint256 value
  ) internal returns (bytes memory) {
    return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
  }

  function functionCallWithValue(
    address target,
    bytes memory data,
    uint256 value,
    string memory errorMessage
  ) internal returns (bytes memory) {
    require(address(this).balance >= value, "Address: insufficient balance for call");
    (bool success, bytes memory returndata) = target.call{value: value}(data);
    return verifyCallResultFromTarget(target, success, returndata, errorMessage);
  }

  function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
    return functionStaticCall(target, data, "Address: low-level static call failed");
  }

  function functionStaticCall(
    address target,
    bytes memory data,
    string memory errorMessage
  ) internal view returns (bytes memory) {
    (bool success, bytes memory returndata) = target.staticcall(data);
    return verifyCallResultFromTarget(target, success, returndata, errorMessage);
  }

  function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
    return functionDelegateCall(target, data, "Address: low-level delegate call failed");
  }

  function functionDelegateCall(
    address target,
    bytes memory data,
    string memory errorMessage
  ) internal returns (bytes memory) {
    (bool success, bytes memory returndata) = target.delegatecall(data);
    return verifyCallResultFromTarget(target, success, returndata, errorMessage);
  }

  function verifyCallResultFromTarget(
    address target,
    bool success,
    bytes memory returndata,
    string memory errorMessage
  ) internal view returns (bytes memory) {
    if (success) {
      if (returndata.length == 0) {
        require(isContract(target), "Address: call to non-contract");
      }
      return returndata;
    } else {
      _revert(returndata, errorMessage);
    }
  }

  function verifyCallResult(
    bool success,
    bytes memory returndata,
    string memory errorMessage
  ) internal pure returns (bytes memory) {
    if (success) {
      return returndata;
    } else {
      _revert(returndata, errorMessage);
    }
  }

  function _revert(bytes memory returndata, string memory errorMessage) private pure {
    if (returndata.length > 0) {
      assembly {
        let returndata_size := mload(returndata)
        revert(add(32, returndata), returndata_size)
      }
    } else {
      revert(errorMessage);
    }
  }
}

library SafeERC20 {
  using Address for address;

  function safeTransfer(
    IERC20 token,
    address to,
    uint256 value
  ) internal {
    _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
  }

  function safeTransferFrom(
    IERC20 token,
    address from,
    address to,
    uint256 value
  ) internal {
    _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
  }

  function safeApprove(
    IERC20 token,
    address spender,
    uint256 value
  ) internal {
    require(
      (value == 0) || (token.allowance(address(this), spender) == 0),
      "SafeERC20: approve from non-zero to non-zero allowance"
    );
    _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
  }

  function safeIncreaseAllowance(
    IERC20 token,
    address spender,
    uint256 value
  ) internal {
    uint256 newAllowance = token.allowance(address(this), spender) + value;
    _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
  }

  function safeDecreaseAllowance(
    IERC20 token,
    address spender,
    uint256 value
  ) internal {
    unchecked {
      uint256 oldAllowance = token.allowance(address(this), spender);
      require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
      uint256 newAllowance = oldAllowance - value;
      _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, newAllowance));
    }
  }

  function safePermit(
    IERC20Permit token,
    address owner,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) internal {
    uint256 nonceBefore = token.nonces(owner);
    token.permit(owner, spender, value, deadline, v, r, s);
    uint256 nonceAfter = token.nonces(owner);
    require(nonceAfter == nonceBefore + 1, "SafeERC20: permit did not succeed");
  }

  function _callOptionalReturn(IERC20 token, bytes memory data) private {
    bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
    if (returndata.length > 0) {
      require(abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
    }
  }
}

interface ISwapPlusv1 {
  struct swapRouter {
    string platform;
    address tokenIn;
    address tokenOut;
    uint256 amountOutMin;
    uint256 meta; // fee, flag(stable), 0=v2
    uint256 percent;
  }
  struct swapLine {
    swapRouter[] swaps;
  }
  struct swapBlock {
    swapLine[] lines;
  }

  function swap(address tokenIn, uint256 amount, address tokenOut, address recipient, swapBlock[] calldata swBlocks) external payable returns(uint256, uint256);
}

contract LiquidXv2Zap {
  using SafeERC20 for IERC20;

  address public router;
  address public factory;
  address public swapPlus;
  address public wrappedETH;
  address public rewarder;

  mapping (address => bool) public operators;
  address public operatorSetter;

  // account => pair => basketId
  mapping (address => mapping(address => mapping(uint256 => uint256))) public balanceOf;

  struct swapPath {
    ISwapPlusv1.swapBlock[] path;
  }

  event Deposit(address account, address token0, address token1, uint256 basketId, uint256 amount);
  event Withdraw(address account, address token0, address token1, uint256 basketId, uint256 amount);

  receive() external payable {
  }

  constructor(address _router, address _swapPlus, address _rewarder, address _wrappedETH) {
    router = _router;
    factory = ILiquidXv2Router01(_router).factory();
    swapPlus = _swapPlus;
    wrappedETH = _wrappedETH;
    rewarder = _rewarder;
    operatorSetter = msg.sender;
  }

  modifier onlyOpertaor() {
    require(operators[msg.sender], "LiquidXv2Zap: !operator");
    _;
  }

  function deposit(address account, address token, address tokenM, swapPath calldata path, address token0, address token1, uint256[3] calldata amount, uint256 basketId) public payable returns(uint256) {
    address pair = ILiquidXv2Factory(factory).getPair(token0, token1);
    require(pair != address(0), "LiquidXv2Zap: no pair");

    // retAddLp 0, 1, 2
    // inAmount
    // token0Amount, token1Amount
    uint256[6] memory lvar;
    lvar[3] = msg.value;
    address inToken = token;
    if (token != address(0)) {
      lvar[3] = IERC20(token).balanceOf(address(this));
      IERC20(token).safeTransferFrom(account, address(this), amount[0]);
      lvar[3] = IERC20(token).balanceOf(address(this)) - lvar[3];
    }
    else {
      inToken = wrappedETH;
      IWETH(wrappedETH).deposit{value: lvar[3]}();
    }

    if (path.path.length > 0) {
      _approveTokenIfNeeded(inToken, swapPlus, lvar[3]);
      (, lvar[3]) = ISwapPlusv1(swapPlus).swap(inToken, lvar[3], tokenM, address(this), path.path);
      inToken = tokenM;
    }

    (lvar[4], lvar[5]) = _depositSwap(token0, token1, inToken, lvar[3]);

    (lvar[0], lvar[1], lvar[2]) = ILiquidXv2Router01(router).addLiquidity(token0, token1, lvar[4], lvar[5], amount[1], amount[2], address(this), block.timestamp);
    _refundReserveToken(account, token0, token1, lvar[4]-lvar[0], lvar[5]-lvar[1]);
    if (basketId == 0) {
      IERC20(pair).safeTransfer(account, lvar[2]);
    }
    else {
      _addBalance(account, pair, basketId, lvar[2]);
    }

    if (rewarder != address(0) && IRewarderv2(rewarder).getReward(account, pair) > 0) {
      IRewarderv2(rewarder).claim(account, pair);
    }

    emit Deposit(account, token0, token1, basketId, lvar[2]);
    return lvar[2];
  }

  function withdraw(address account, address token0, address token1, uint256 amount, address tokenOut, uint256 basketId, address tokenM, swapPath calldata wpath, uint256[3] memory amountMin) public returns(uint256) {
    address pair = ILiquidXv2Factory(factory).getPair(token0, token1);
    require(pair != address(0), "LiquidXv2Zap: no pair");

    if (basketId == 0) {
      IERC20(pair).safeTransferFrom(account, address(this), amount);
    }
    else {
      require(account == msg.sender || operators[msg.sender], "LiquidXv2Zap: no access");
      if (balanceOf[account][pair][basketId] < amount) {
        amount = balanceOf[account][pair][basketId];
      }
      balanceOf[account][pair][basketId] -= amount;
    }

    if (amount == 0) return 0;

    _approveTokenIfNeeded(pair, router, amount);
    // amount0, 1
    // outAmount
    uint256[3] memory vamount;
    (vamount[0], vamount[1]) = ILiquidXv2Router01(router).removeLiquidity(token0, token1, amount, amountMin[0], amountMin[1], address(this), block.timestamp);

    address tOut = tokenOut; 
    if (tokenOut == address(0)) {
      tOut = wrappedETH;
    }

    vamount[2] = 0;
    if (tOut == token1) {
      vamount[2] = vamount[1];
      _approveTokenIfNeeded(token0, router, vamount[0]);
      address[] memory path = new address[](2);
      path[0] = token0;
      path[1] = token1;
      uint256[] memory ret = ILiquidXv2Router01(router).swapExactTokensForTokens(vamount[0], amountMin[2], path, address(this), block.timestamp);
      vamount[2] += ret[1];
    }
    else {
      vamount[2] = vamount[0];
      _approveTokenIfNeeded(token1, router, vamount[1]);
      address[] memory path = new address[](2);
      path[0] = token1;
      path[1] = token0;
      uint256[] memory ret = ILiquidXv2Router01(router).swapExactTokensForTokens(vamount[1], amountMin[2], path, address(this), block.timestamp);
      vamount[2] += ret[1];
    }

    if (wpath.path.length > 0) {
      _approveTokenIfNeeded(tokenOut, swapPlus, vamount[2]);
      (, vamount[2]) = ISwapPlusv1(swapPlus).swap(tokenOut, vamount[2], tokenM==address(0)?wrappedETH:tokenM, address(this), wpath.path);
      tokenOut = tokenM;
    }

    if (tokenOut != address(0)) {
      IERC20(tokenOut).safeTransfer(account, vamount[2]);
    }
    else {
      IWETH(wrappedETH).withdraw(vamount[2]);
      (bool success, ) = payable(account).call{value: vamount[2]}("");
      require(success, "LiquidXv2Zap: Failed withdraw");
    }

    if (rewarder != address(0) && IRewarderv2(rewarder).getReward(account, pair) > 0) {
      IRewarderv2(rewarder).claim(account, pair);
    }

    emit Withdraw(account, token0, token1, basketId, amount);
    return vamount[2];
  }

  function _depositSwap(address token0, address token1, address inToken, uint256 inAmount) internal returns(uint256, uint256) {
    address pair = ILiquidXv2Factory(factory).getPair(token0, token1);

    bool isToken0 = false;
    address outToken = token0;
    uint256 reserve = 0;
    if (inToken == token0) {
      isToken0 = true;
      outToken = token1;
      (reserve, , ) = ILiquidXv2Pair(pair).getReserves();
    }
    else {
      (, reserve, ) = ILiquidXv2Pair(pair).getReserves();
    }

    _approveTokenIfNeeded(inToken, router, inAmount);
    uint256 swapAmount = _calculateSwapAmount(reserve, inAmount);

    address[] memory path = new address[](2);
    path[0] = inToken;
    path[1] = outToken;
    uint256[] memory ret = ILiquidXv2Router01(router).swapExactTokensForTokens(swapAmount, 0, path, address(this), block.timestamp);
    inAmount = inAmount - ret[0];

    _approveTokenIfNeeded(outToken, router, ret[1]);

    if (isToken0) {
      return (inAmount, ret[1]);
    }
    else {
      return (ret[1], inAmount);
    }
  }

  function _refundReserveToken(address account, address token0, address token1, uint256 amount0, uint256 amount1) internal {
    if (amount0 > 0) {
      IERC20(token0).safeTransfer(account, amount0);
    }
    if (amount1 > 0) {
      IERC20(token1).safeTransfer(account, amount1);
    }
  }

  function _calculateSwapAmount(uint256 reserve, uint256 inAmount) internal pure returns(uint256) {
    // (sqrt(reserve^2*(1+C)^2 + 4C*reserve*inAmount) - reserve*(1+C)) / 2C
    uint256 a1 = reserve * reserve * 1997 *1997;
    uint256 a2 = 4 * 997 * reserve * inAmount * 1000;
    return (_sqrt(a1+a2) - reserve * 1997) / (2 * 997);
  }

  function _sqrt(uint x) internal pure returns (uint y) {
    uint z = (x + 1) / 2;
    y = x;
    while (z < y) {
      y = z;
      z = (x / z + z) / 2;
    }
  }

  function _addBalance(address account, address pair, uint256 basketId, uint256 amount) internal {
    balanceOf[account][pair][basketId] += amount;
  }

  function withdrawToken(address token, address target, uint256 amount) public onlyOpertaor {
    if (token == address(0)) {
      (bool success, ) = payable(target).call{value: amount}("");
      require(success, "LiquidXv2Zap: Failed withdraw");
    }
    else {
      IERC20(token).safeTransfer(target, amount);
    }
  }

  function setRouterAndFactory(address _router) public {
    require(msg.sender == operatorSetter, 'LiquidXv2Zap: FORBIDDEN');
    router = _router;
    factory = ILiquidXv2Router01(_router).factory();
  }

  function setSwapPlus(address _swapPlus) public {
    require(msg.sender == operatorSetter, 'LiquidXv2Zap: FORBIDDEN');
    swapPlus = _swapPlus;
  }

  function setRewarder(address _rewarder) public {
    require(msg.sender == operatorSetter, 'LiquidXv2Zap: FORBIDDEN');
    rewarder = _rewarder;
  }

  function setOperator(address _operator, bool mode) external {
    require(msg.sender == operatorSetter, 'LiquidXv2Zap: FORBIDDEN');
    operators[_operator] = mode;
  }

  function setOperatorSetter(address _operatorSetter) external {
    require(msg.sender == operatorSetter, 'LiquidXv2Zap: FORBIDDEN');
    operatorSetter = _operatorSetter;
  }

  function _approveTokenIfNeeded(address token, address spender, uint256 amount) private {
    uint256 oldAllowance = IERC20(token).allowance(address(this), spender);
    if (oldAllowance < amount) {
      if (oldAllowance > 0) {
        IERC20(token).safeApprove(spender, 0);
      }
      IERC20(token).safeApprove(spender, type(uint256).max);
    }
  }
}