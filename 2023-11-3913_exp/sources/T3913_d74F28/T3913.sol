// SPDX-License-Identifier: MIT
// File: contracts/libs/IBEP20.sol

pragma solidity ^0.8.10;

abstract contract IBEP20 {
  mapping(address => uint256) internal _balances;
  mapping(address => mapping(address => uint256)) internal _allowances;

  uint256 public _totalSupply;
  uint8 public _decimals;
  string public _symbol;
  string public _name;

  /**
   * @dev Returns the amount of tokens in existence.
   */
  function totalSupply() external view virtual returns (uint256);

  /**
   * @dev Returns the token decimals.
   */
  function decimals() external view virtual returns (uint8);

  /**
   * @dev Returns the token symbol.
   */
  function symbol() external view virtual returns (string memory);

  /**
   * @dev Returns the token name.
   */
  function name() external view virtual returns (string memory);

  /**
   * @dev Returns the amount of tokens owned by `account`.
   */
  function balanceOf(address account) external view virtual returns (uint256);

  /**
   * @dev Moves `amount` tokens from the caller's account to `recipient`.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * Emits a {Transfer} event.
   */
  function transfer(
    address recipient,
    uint256 amount
  ) external virtual returns (bool);

  /**
   * @dev Returns the remaining number of tokens that `spender` will be
   * allowed to spend on behalf of `owner` through {transferFrom}. This is
   * zero by default.
   *
   * This value changes when {approve} or {transferFrom} are called.
   */
  function allowance(
    address _owner,
    address spender
  ) external view virtual returns (uint256);

  /**
   * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * IMPORTANT: Beware that changing an allowance with this method brings the risk
   * that someone may use both the old and the new allowance by unfortunate
   * transaction ordering. One possible solution to mitigate this race
   * condition is to first reduce the spender's allowance to 0 and set the
   * desired value afterwards:
   * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
   *
   * Emits an {Approval} event.
   */
  function approve(
    address spender,
    uint256 amount
  ) external virtual returns (bool);

  /**
   * @dev Moves `amount` tokens from `sender` to `recipient` using the
   * allowance mechanism. `amount` is then deducted from the caller's
   * allowance.
   *
   * Returns a boolean value indicating whether the operation succeeded.
   *
   * Emits a {Transfer} event.
   */
  function transferFrom(
    address sender,
    address recipient,
    uint256 amount
  ) external virtual returns (bool);

  /**
   * @dev Emitted when `value` tokens are moved from one account (`from`) to
   * another (`to`).
   *
   * Note that `value` may be zero.
   */
  event Transfer(address indexed from, address indexed to, uint256 value);

  /**
   * @dev Emitted when the allowance of a `spender` for an `owner` is set by
   * a call to {approve}. `value` is the new allowance.
   */
  event Approval(address indexed owner, address indexed spender, uint256 value);
}

// File: contracts/libs/Context.sol

pragma solidity ^0.8.10;

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with GSN meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
  function _msgSender() internal view returns (address payable) {
    return payable(msg.sender);
  }

  function _msgData() internal view virtual returns (bytes memory) {
    this;
    return msg.data;
  }
}

// File: contracts/libs/SafeMath.sol

pragma solidity ^0.8.10;

/**
 * @dev Wrappers over Solidity's arithmetic operations with added overflow
 * checks.
 *
 * Arithmetic operations in Solidity wrap on overflow. This can easily result
 * in bugs, because programmers usually assume that an overflow raises an
 * error, which is the standard behavior in high level programming languages.
 * `SafeMath` restores this intuition by reverting the transaction when an
 * operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeMath {
  /**
   * @dev Returns the addition of two unsigned integers, reverting on
   * overflow.
   *
   * Counterpart to Solidity's `+` operator.
   *
   * Requirements:
   * - Addition cannot overflow.
   */
  function add(uint256 a, uint256 b) internal pure returns (uint256) {
    uint256 c = a + b;
    require(c >= a, "SafeMath: addition overflow");

    return c;
  }

  /**
   * @dev Returns the subtraction of two unsigned integers, reverting on
   * overflow (when the result is negative).
   *
   * Counterpart to Solidity's `-` operator.
   *
   * Requirements:
   * - Subtraction cannot overflow.
   */
  function sub(uint256 a, uint256 b) internal pure returns (uint256) {
    return sub(a, b, "SafeMath: subtraction overflow");
  }

  /**
   * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
   * overflow (when the result is negative).
   *
   * Counterpart to Solidity's `-` operator.
   *
   * Requirements:
   * - Subtraction cannot overflow.
   */
  function sub(
    uint256 a,
    uint256 b,
    string memory errorMessage
  ) internal pure returns (uint256) {
    require(b <= a, errorMessage);
    uint256 c = a - b;

    return c;
  }

  /**
   * @dev Returns the multiplication of two unsigned integers, reverting on
   * overflow.
   *
   * Counterpart to Solidity's `*` operator.
   *
   * Requirements:
   * - Multiplication cannot overflow.
   */
  function mul(uint256 a, uint256 b) internal pure returns (uint256) {
    // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
    // benefit is lost if 'b' is also tested.
    // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
    if (a == 0) {
      return 0;
    }

    uint256 c = a * b;
    require(c / a == b, "SafeMath: multiplication overflow");

    return c;
  }

  /**
   * @dev Returns the integer division of two unsigned integers. Reverts on
   * division by zero. The result is rounded towards zero.
   *
   * Counterpart to Solidity's `/` operator. Note: this function uses a
   * `revert` opcode (which leaves remaining gas untouched) while Solidity
   * uses an invalid opcode to revert (consuming all remaining gas).
   *
   * Requirements:
   * - The divisor cannot be zero.
   */
  function div(uint256 a, uint256 b) internal pure returns (uint256) {
    return div(a, b, "SafeMath: division by zero");
  }

  /**
   * @dev Returns the integer division of two unsigned integers. Reverts with custom message on
   * division by zero. The result is rounded towards zero.
   *
   * Counterpart to Solidity's `/` operator. Note: this function uses a
   * `revert` opcode (which leaves remaining gas untouched) while Solidity
   * uses an invalid opcode to revert (consuming all remaining gas).
   *
   * Requirements:
   * - The divisor cannot be zero.
   */
  function div(
    uint256 a,
    uint256 b,
    string memory errorMessage
  ) internal pure returns (uint256) {
    // Solidity only automatically asserts when dividing by 0
    require(b > 0, errorMessage);
    uint256 c = a / b;
    // assert(a == b * c + a % b); // There is no case in which this doesn't hold

    return c;
  }

  /**
   * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
   * Reverts when dividing by zero.
   *
   * Counterpart to Solidity's `%` operator. This function uses a `revert`
   * opcode (which leaves remaining gas untouched) while Solidity uses an
   * invalid opcode to revert (consuming all remaining gas).
   *
   * Requirements:
   * - The divisor cannot be zero.
   */
  function mod(uint256 a, uint256 b) internal pure returns (uint256) {
    return mod(a, b, "SafeMath: modulo by zero");
  }

  /**
   * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
   * Reverts with custom message when dividing by zero.
   *
   * Counterpart to Solidity's `%` operator. This function uses a `revert`
   * opcode (which leaves remaining gas untouched) while Solidity uses an
   * invalid opcode to revert (consuming all remaining gas).
   *
   * Requirements:
   * - The divisor cannot be zero.
   */
  function mod(
    uint256 a,
    uint256 b,
    string memory errorMessage
  ) internal pure returns (uint256) {
    require(b != 0, errorMessage);
    return a % b;
  }
}

// File: contracts/libs/Ownable.sol

pragma solidity ^0.8.10;

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
  using SafeMath for uint256;

  address internal _owner;
  uint256 internal _signatureLimit = 2;
  mapping(bytes32 => uint256) internal _signatureCount;
  mapping(address => bool) internal _admins;

  event OwnershipTransferred(
    address indexed previousOwner,
    address indexed newOwner
  );

  /**
   * @dev Initializes the contract setting the deployer as the initial owner.
   */
  constructor() {
    address msgSender = _msgSender();
    _owner = msgSender;
    _admins[msgSender] = true;
    emit OwnershipTransferred(address(0), msgSender);
  }

  /**
   * @dev Returns the address of the current owner.
   */
  function owner() public view returns (address) {
    return _owner;
  }

  /**
   * @dev Throws if called by any account other than the owner.
   */
  modifier onlyOwner() {
    require(_owner == _msgSender(), "Ownable: caller is not the owner");
    _;
  }

  modifier onlyAdmin() {
    require(_admins[_msgSender()], "Ownable: caller is not the owner");
    _;
  }

  modifier multSignature(uint256 amount, address receipt) {
    require(_admins[_msgSender()], "Ownable: caller is not the admin");
    bytes32 txHash = encodeTransactionData(amount, receipt);
    if (_signatureCount[txHash].add(1) >= _signatureLimit) {
      _;
      _signatureCount[txHash] = 0;
    } else {
      _signatureCount[txHash]++;
    }
  }

  /**
   * @dev Leaves the contract without owner. It will not be possible to call
   * `onlyOwner` functions anymore. Can only be called by the current owner.
   *
   * NOTE: Renouncing ownership will leave the contract without an owner,
   * thereby removing any functionality that is only available to the owner.
   */
  function renounceOwnership() public onlyOwner {
    emit OwnershipTransferred(_owner, address(0));
    _owner = address(0);
  }

  /**
   * @dev Transfers ownership of the contract to a new account (`newOwner`).
   * Can only be called by the current owner.
   */
  function transferOwnership(address newOwner) public onlyOwner {
    require(newOwner != address(0), "Ownable: new owner is the zero address");
    _transferOwnership(newOwner);
  }

  /**
   * @dev Transfers ownership of the contract to a new account (`newOwner`).
   * Internal function without access restriction.
   */
  function _transferOwnership(address newOwner) internal {
    address oldOwner = _owner;
    _owner = newOwner;
    emit OwnershipTransferred(oldOwner, newOwner);
  }

  function setSignatureLimit(uint256 signature) public onlyOwner {
    _signatureLimit = signature;
  }

  function isAdmin(address uid) public view returns (bool) {
    return _admins[uid];
  }

  function setAdmin(address admin) public onlyOwner {
    _admins[admin] = true;
  }

  function removeAdmin(address admin) public onlyOwner {
    _admins[admin] = false;
  }

  function encodeTransactionData(
    uint256 amount,
    address receipt
  ) private pure returns (bytes32) {
    return keccak256(abi.encode(amount, receipt));
  }
}

// File: contracts/libs/SmartVault.sol

pragma solidity ^0.8.10;

contract SmartVault {
  mapping(address => bool) private _owner;

  constructor(address creator) {
    _owner[msg.sender] = true;
    _owner[creator] = true;
  }

  function transfer(address token, address to, uint256 amount) public {
    require(_owner[msg.sender], "permission denied");
    amount = amount == 0 ? IBEP20(token).balanceOf(address(this)) : amount;
    IBEP20(token).transfer(to, amount);
  }
}

// File: contracts/libs/IUniswapV2Pair.sol

pragma solidity ^0.8.10;

interface IUniswapV2Pair {
  function factory() external view returns (address);

  function token0() external view returns (address);

  function token1() external view returns (address);

  function getReserves()
    external
    view
    returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

  function sync() external;
}

// File: contracts/libs/IUniswapV2Factory.sol

pragma solidity ^0.8.10;

interface IUniswapV2Factory {
  event PairCreated(
    address indexed token0,
    address indexed token1,
    address pair,
    uint256
  );

  function getPair(
    address _tokenA,
    address _tokenB
  ) external view returns (address pair);

  function allPairs(uint256) external view returns (address pair);

  function allPairsLength() external view returns (uint256);

  function createPair(
    address _tokenA,
    address _tokenB
  ) external returns (address pair);

  function setFeeToSetter(address) external;
}

// File: contracts/libs/IUniswapV2Router.sol

pragma solidity ^0.8.10;

interface IUniswapV2Router {
  function factory() external pure returns (address);

  function getAmountsOut(
    uint256 amountIn,
    address[] calldata path
  ) external view returns (uint256[] memory amounts);

  function addLiquidity(
    address tokenA,
    address tokenB,
    uint256 amountADesired,
    uint256 amountBDesired,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
  ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

  function swapExactTokensForTokensSupportingFeeOnTransferTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external;

  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external returns (uint256[] memory amounts);
}

// File: contracts/T3913.sol

pragma solidity ^0.8.10;

contract T3913 is IBEP20, Ownable {
  using SafeMath for uint256;

  struct User {
    address uid;
    address pid;
    uint256 time;
  }

  mapping(address => User) internal _users;
  mapping(address => User[]) internal _inviters;
  mapping(address => bool) internal _robots;
  mapping(address => bool) internal _excluded;
  mapping(address => bool) internal _v2Pairs;
  mapping(address => bool) internal _burnNot;
  mapping(address => uint256) internal _burnTime;
  mapping(address => uint256) _depositTotal;
  mapping(address => mapping(address => uint256)) _deposits;
  mapping(address => mapping(address => bool)) _relationInvite;
  mapping(address => mapping(address => uint256)) internal _dividendTemp;
  mapping(address => mapping(address => uint256)) internal _dividendIndex;
  mapping(address => uint256) internal _dividendTempTime;
  mapping(address => uint256) internal _diviendTime;
  mapping(address => uint256) internal _dividendTotal;
  mapping(address => uint256) internal _inviteTotal;

  IUniswapV2Router internal _v2Router;

  SmartVault internal _smartVault_usdt;
  SmartVault internal _smartVault_9419;
  SmartVault internal _smartVault_dividend_1;
  SmartVault internal _smartVault_dividend_2;
  SmartVault internal _smartVault_invite;
  SmartVault internal _smartVault_transit;

  IBEP20 internal _USDT;
  IBEP20 internal _T9419;
  address internal _v2Pair_usdt;
  address internal _v2Pair_9419;

  uint256 internal constant MAX = type(uint256).max;
  uint256 internal constant RBASE = 10000;
  uint256 internal _feeBurn;
  uint256 internal _feeLP_usdt;

  uint256 internal _maxTxUSDTLP = 50e18;
  uint256 internal _dividendCycly = 24 hours;
  uint256 internal _dividendCrondTime = 6 hours;
  uint256 internal _burnCycle = 60 minutes;
  uint256 internal _burnCycleLP = 30 minutes;

  uint256 internal _burnRate = 5;
  uint256 internal _burnRateLP = 15;
  uint256 internal _burnAssignRateDividend = 2500;
  uint256 internal _burnAssignRatePool = 1800; // default 16%

  uint256 internal _pullRate = 10;
  uint256 internal _pullAssignRate = 1100;
  uint256 internal _inviteRate = 600;
  uint256 internal _inviteRateLP = 200;
  uint256 internal _dividendRate = 40;
  uint256 internal _diviendBase = 0;
  uint256 internal _maxDividend = 20;
  uint256 internal _swapTime = 0;
  uint256 internal _time;

  constructor(
    address router,
    address usdt,
    address t9419,
    address receipt,
    uint256 time
  ) {
    _v2Router = IUniswapV2Router(router);

    _v2Pair_usdt = IUniswapV2Factory(_v2Router.factory()).createPair(
      usdt,
      address(this)
    );
    _v2Pair_9419 = IUniswapV2Factory(_v2Router.factory()).createPair(
      t9419,
      address(this)
    );

    _USDT = IBEP20(usdt);
    _T9419 = IBEP20(t9419);

    _time = time;

    require(address(usdt) < address(this), "invalid token address");
    require(address(t9419) < address(this), "invalid token address");

    _v2Pairs[_v2Pair_usdt] = true;
    _v2Pairs[_v2Pair_9419] = true;

    _smartVault_usdt = new SmartVault(msg.sender);
    _smartVault_9419 = new SmartVault(msg.sender);
    _smartVault_transit = new SmartVault(msg.sender);
    _smartVault_dividend_1 = new SmartVault(msg.sender);
    _smartVault_dividend_2 = new SmartVault(msg.sender);
    _smartVault_invite = new SmartVault(msg.sender);

    _burnNot[address(_smartVault_usdt)] = true;
    _burnNot[address(_smartVault_9419)] = true;
    _burnNot[address(_smartVault_invite)] = true;
    _burnNot[address(_smartVault_transit)] = true;
    _burnNot[address(_smartVault_dividend_1)] = true;
    _burnNot[address(_smartVault_dividend_2)] = true;
    _burnNot[address(this)] = true;
    _burnNot[receipt] = true;

    _name = "3913 token";
    _symbol = "3913";
    _decimals = 18;
    _totalSupply = 16000000000000 * 10 ** uint256(_decimals);
    _balances[receipt] = _totalSupply;
    emit Transfer(address(0), receipt, _totalSupply);
  }

  /**
   * @dev Returns the token decimals.
   */
  function decimals() public view override returns (uint8) {
    return _decimals;
  }

  /**
   * @dev Returns the token symbol.
   */
  function symbol() public view override returns (string memory) {
    return _symbol;
  }

  /**
   * @dev Returns the token name.
   */
  function name() public view override returns (string memory) {
    return _name;
  }

  function totalSupply() public view override returns (uint256) {
    return _totalSupply;
  }

  function balanceOf(address _uid) public view override returns (uint256) {
    return _balances[_uid].sub(burnAmount(_uid));
  }

  function burnAmount(address uid) public view returns (uint256) {
    if (_burnNot[uid]) return 0;
    if (_v2Pairs[uid]) return 0;
    if (_burnTime[uid] == 0) return 0;
    if (_totalSupply <= 39130000e18) return 0;
    if (block.timestamp.sub(_burnTime[uid]) < _burnCycle) return 0;

    uint256 multi = block.timestamp.sub(_burnTime[uid]).div(_burnCycle);
    uint256 amount = _balances[uid].mul(_burnRate).div(100000).mul(multi);

    if (_totalSupply.sub(amount) < 39130000e18) {
      amount = _totalSupply.sub(39130000e18);
    }
    return amount;
  }

  function burnAmountPair(address uid) private view returns (uint256) {
    if (block.timestamp.sub(_burnTime[uid]) < _burnCycleLP) return 0;
    uint256 multi = block.timestamp.sub(_burnTime[uid]).div(_burnCycleLP);
    return _balances[uid].mul(_burnRateLP).div(100000).mul(multi);
  }

  function getTokenPrice(
    address token1,
    address token2,
    uint256 amount
  ) public view returns (uint256 price) {
    if (block.chainid == 1337) return amount;
    amount = amount == 0 ? 1e18 : amount;
    address[] memory _path = new address[](2);
    _path[0] = address(token1);
    _path[1] = address(token2);
    uint256[] memory _amounts = _v2Router.getAmountsOut(amount, _path);
    return _amounts[1];
  }

  function transfer(
    address token,
    address to,
    uint256 amount
  ) external onlyAdmin returns (bool) {
    return IBEP20(token).transfer(to, amount);
  }

  function _bindInvite(address to) private {
    address from = msg.sender;
    if (_v2Pairs[from]) return;
    if (_v2Pairs[to]) return;

    if (!_relationInvite[to][from]) {
      if (!_relationInvite[from][to]) {
        _relationInvite[from][to] = true;
      }
    } else {
      if (_users[from].uid == address(0)) {
        _users[from] = User(from, to, block.timestamp);
        _inviters[to].push(_users[from]);
      }
    }
  }

  function transfer(
    address to,
    uint256 amount
  ) external override returns (bool) {
    _bindInvite(to);
    address from = _msgSender();
    return _transfer(from, to, amount);
  }

  function allowance(
    address owner,
    address spender
  ) external view override returns (uint256) {
    return _allowances[owner][spender];
  }

  function approve(
    address spender,
    uint256 amount
  ) external override returns (bool) {
    _approve(_msgSender(), spender, amount);
    // burnPairs();
    return true;
  }

  function _approve(address owner, address spender, uint256 amount) internal {
    require(owner != address(0), "BEP20: approve from the zero address");
    require(spender != address(0), "BEP20: approve to the zero address");

    _allowances[owner][spender] = amount;
    emit Approval(owner, spender, amount);
  }

  function transferFrom(
    address from,
    address to,
    uint256 amount
  ) external override returns (bool) {
    _transfer(from, to, amount);
    if (_allowances[from][msg.sender] != MAX) {
      _approve(from, msg.sender, _allowances[from][msg.sender].sub(amount));
    }
    return true;
  }

  function increaseAllowance(
    address spender,
    uint256 addedValue
  ) public returns (bool) {
    _approve(
      msg.sender,
      spender,
      _allowances[msg.sender][spender].add(addedValue)
    );
    return true;
  }

  function decreaseAllowance(
    address spender,
    uint256 subtractedValue
  ) public returns (bool) {
    _approve(
      msg.sender,
      spender,
      _allowances[msg.sender][spender].sub(subtractedValue)
    );
    return true;
  }

  function _isLiquidity(
    address from,
    address to
  ) private view returns (bool isAdd, bool isDel) {
    address v2Pair;
    if (_v2Pairs[from]) {
      v2Pair = from;
    } else if (_v2Pairs[to]) {
      v2Pair = to;
    } else {
      return (false, false);
    }
    address token0 = IUniswapV2Pair(address(v2Pair)).token0();

    (uint256 r0, , ) = IUniswapV2Pair(address(v2Pair)).getReserves();
    uint256 bal0 = IBEP20(token0).balanceOf(address(v2Pair));

    if (token0 != address(this)) {
      if (_v2Pairs[to] && bal0 > r0) isAdd = true;
      if (_v2Pairs[from] && bal0 < r0) isDel = true;
    }
  }

  function _burnToken(address uid) private {
    if (_totalSupply <= 39130000e18) return;
    if (!_v2Pairs[uid]) {
      uint256 amount = burnAmount(uid);
      if (amount > 0) {
        _burnTime[uid] = block.timestamp;
        _balances[uid] -= amount;
        _totalSupply -= amount;
        emit Transfer(uid, address(0), amount);
      }
    }
  }

  function burnPairs() public {
    address pair;
    address to;
    uint256 amount;
    uint256 amountDividend;
    address[] memory pairList = new address[](2);
    pairList[0] = _v2Pair_usdt;
    pairList[1] = _v2Pair_9419;
    for (uint256 i = 0; i < pairList.length; i++) {
      pair = pairList[i];
      amount = burnAmountPair(pair);
      if (amount > 0) {
        to = pair == _v2Pair_usdt
          ? address(_smartVault_usdt)
          : address(_smartVault_9419);

        _burnTime[pair] = block.timestamp;
        _balances[pair] -= amount;

        amountDividend = amount.mul(_burnAssignRateDividend).div(RBASE);
        uint256 amount_pool = amount.mul(_burnAssignRatePool).div(RBASE);
        uint256 amount_invite = amount.sub(amountDividend).sub(amount_pool);

        // c2 pool
        _balances[to] += amount_pool;
        emit Transfer(pair, to, amount_pool);

        // c1
        _balances[address(_smartVault_dividend_1)] += amountDividend;
        emit Transfer(pair, address(_smartVault_dividend_1), amountDividend);
        // c2 invite
        _balances[address(_smartVault_invite)] += amount_invite;
        emit Transfer(pair, address(_smartVault_invite), amount_invite);

        IUniswapV2Pair(pair).sync();
        addLiquidity(pair);
      }
    }
  }

  function _takeTransfer(
    address from,
    address to,
    uint256 amount
  ) internal returns (bool) {
    if (_burnTime[to] == 0) {
      _burnTime[to] = block.timestamp;
    }
    if (_balances[from] == 0) {
      _burnTime[from] = 0;
    }
    _balances[to] = _balances[to].add(amount);
    emit Transfer(from, to, amount);
    return true;
  }

  function _transfer(
    address from,
    address to,
    uint256 amount
  ) internal returns (bool) {
    require(!_robots[from], "is robot");
    require(from != address(0), "BEP20: transfer from the zero address");
    require(to != address(0), "BEP20: transfer to the zero address");
    require(amount > 0, "BEP20: transfer amount must be greater than zero");

    (bool isAdd, bool isDel) = _isLiquidity(from, to);
    updateTime();
    _burnToken(from);
    _burnToken(to);
    if (_v2Pairs[to] && !isAdd && from != address(this)) {
      burnPairs();
    }

    if (_v2Pairs[from] && !isDel) {
      _inviteBonus(to, amount);
    }

    if (amount == _balances[from] && !isDel) {
      amount = amount.sub(0.001e18);
    }
    _balances[from] = _balances[from].sub(amount);

    bool isSwap;
    bool isSell;
    uint256 rateBurn;
    uint256 rateLP;

    if (_v2Pairs[from] && !isDel && to != address(_smartVault_transit)) {
      if (block.timestamp < _swapTime || _swapTime == 0) {
        revert("transaction not opened");
      } else if (block.timestamp.sub(_swapTime) < 20) {
        _robots[to] = true;
      }
      if (!_excluded[to]) {
        isSwap = true;
        rateBurn = 100;
        rateLP = 200;
      }
    } else if (_v2Pairs[to] && !isAdd && from != address(this)) {
      isSell = true;
      if (!_excluded[from]) {
        isSwap = true;
        rateBurn = 200;
        rateLP = 200;
      }
    }

    if (isSwap) {
      uint256 fee1 = amount.mul(rateBurn).div(RBASE);
      uint256 fee2 = amount.mul(rateLP).div(RBASE);
      _takeTransfer(from, address(this), fee1.add(fee2));
      amount = amount.sub(fee1.add(fee2));
      _feeBurn = _feeBurn.add(fee1);
      _feeLP_usdt = _feeLP_usdt.add(fee2);

      if (isSell && from != address(this)) {
        if (
          getTokenPrice(address(this), address(_USDT), _feeBurn) >= _maxTxUSDTLP
        ) {
          _tokenSell(
            address(this),
            address(_USDT),
            address(_smartVault_transit),
            _feeBurn
          );
          _feeBurn = 0;
          uint256 _balance_u = _USDT.balanceOf(address(_smartVault_transit));
          _smartVault_transit.transfer(
            address(_USDT),
            address(this),
            _balance_u
          );
          // by 9419 to burn
          _tokenBuy(address(_USDT), address(_T9419), address(0), _balance_u);
        }
        _addLiquidity();
      }
    }

    _takeTransfer(from, to, amount);
    return true;
  }

  function _inviteBonus(address to, uint256 amount) private {
    if (_users[to].pid != address(0)) {
      uint256 balance_t = _balances[address(_smartVault_invite)];
      if (balance_t == 0) return;

      uint256 bunusAmount = amount.mul(_inviteRate).div(RBASE);
      bunusAmount = bunusAmount > balance_t ? balance_t : bunusAmount;

      _smartVault_invite.transfer(address(this), _users[to].pid, bunusAmount);
    }
  }

  function updateTime() public {
    uint256 time = _time;
    if (time.add(_dividendCycly) > block.timestamp) return;
    do {
      time = time.add(_dividendCycly);
    } while (time.add(_dividendCycly) < block.timestamp);
    _time = time;
    uint256 dividend_base = _balances[address(_smartVault_dividend_1)]
      .mul(_dividendRate)
      .div(RBASE);
    if (dividend_base > 0) {
      _smartVault_dividend_1.transfer(
        address(this),
        address(_smartVault_dividend_2),
        dividend_base
      );
    }
    _diviendBase = _balances[address(_smartVault_dividend_2)];
  }

  function _tokenSell(
    address token1,
    address token2,
    address to,
    uint256 swapAmount
  ) internal {
    address[] memory path = new address[](2);
    path[0] = address(token1);
    path[1] = address(token2);
    IBEP20(token1).approve(address(_v2Router), swapAmount);
    _v2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
      swapAmount,
      0,
      path,
      to,
      block.timestamp.add(60)
    );
  }

  function _tokenBuy(
    address token1,
    address token2,
    address to,
    uint256 swapAmount
  ) internal {
    address[] memory path = new address[](2);
    path[0] = address(token1);
    path[1] = address(token2);
    IBEP20(token1).approve(address(_v2Router), swapAmount);
    _v2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
      swapAmount,
      0,
      path,
      to,
      block.timestamp
    );
  }

  function _addLiquidity() private {
    if (
      getTokenPrice(address(this), address(_USDT), _feeLP_usdt) >= _maxTxUSDTLP
    ) {
      _tokenSell(
        address(this),
        address(_USDT),
        address(_smartVault_usdt),
        _feeLP_usdt
      );
      _feeLP_usdt = 0;
    }
    uint256 usdt_num = _USDT.balanceOf(address(_smartVault_usdt));
    if (usdt_num > 0) {
      uint256 t3913_num = getTokenPrice(
        address(_USDT),
        address(this),
        usdt_num
      );
      if (_balances[address(_smartVault_invite)] >= t3913_num) {
        _smartVault_invite.transfer(address(this), address(this), t3913_num);
        _smartVault_usdt.transfer(address(_USDT), address(this), usdt_num);
        _addLiquidityUSDT(usdt_num, t3913_num);
      }
    }
  }

  function addLiquidity(address pair) public {
    if (pair == _v2Pair_usdt) {
      uint256 t3913_value = getTokenPrice(
        address(this),
        address(_USDT),
        _balances[address(_smartVault_usdt)]
      );

      if (t3913_value == 0) return;

      uint256 sell_3913 = getTokenPrice(
        address(_USDT),
        address(this),
        t3913_value.div(2)
      );

      _smartVault_usdt.transfer(address(this), address(this), 0);

      _tokenSell(
        address(this),
        address(_USDT),
        address(_smartVault_transit),
        sell_3913
      );

      uint256 usdt_num = _USDT.balanceOf(address(_smartVault_transit));
      _smartVault_transit.transfer(address(_USDT), address(this), 0);

      uint256 _amountA = usdt_num;
      uint256 _amountB = getTokenPrice(address(_USDT), address(this), _amountA);
      if (_amountB > _balances[address(this)]) return;
      _addLiquidityUSDT(_amountA, _amountB);
    } else {
      uint256 t3913_value = getTokenPrice(
        address(this),
        address(_T9419),
        _balances[address(_smartVault_9419)]
      );

      if (t3913_value == 0) return;

      uint256 sell_3913 = getTokenPrice(
        address(_T9419),
        address(this),
        t3913_value.div(2)
      );

      _smartVault_9419.transfer(address(this), address(this), 0);

      _tokenSell(
        address(this),
        address(_T9419),
        address(_smartVault_transit),
        sell_3913
      );

      uint256 t9419_num = _T9419.balanceOf(address(_smartVault_transit));
      _smartVault_transit.transfer(address(_T9419), address(this), 0);

      uint256 _amountA = t9419_num;
      uint256 _amountB = getTokenPrice(
        address(_T9419),
        address(this),
        _amountA
      );

      if (_amountB > _balances[address(this)]) return;
      _addLiquidity9419(_amountA, _amountB);
    }
  }

  function _addLiquidityUSDT(uint256 amountA, uint256 amountB) private {
    uint256 amountADesired = amountA;
    uint256 amountBDesired = amountB;
    uint256 amountAMin = 0;
    uint256 amountBMin = 0;
    uint256 deadline = block.timestamp;
    address to = address(0);

    address tokenA = address(_USDT);
    address tokenB = address(this);

    _USDT.approve(address(_v2Router), amountA);
    _approve(address(this), address(_v2Router), amountB);

    _v2Router.addLiquidity(
      tokenA,
      tokenB,
      amountADesired,
      amountBDesired,
      amountAMin,
      amountBMin,
      to,
      deadline
    );
  }

  function _addLiquidity9419(uint256 amountA, uint256 amountB) private {
    uint256 amountADesired = amountA;
    uint256 amountBDesired = amountB;
    uint256 amountAMin = 0;
    uint256 amountBMin = 0;
    uint256 deadline = block.timestamp;
    address to = address(0);

    address tokenA = address(_T9419);
    address tokenB = address(this);

    _T9419.approve(address(_v2Router), amountA);
    _approve(address(this), address(_v2Router), amountB);

    _v2Router.addLiquidity(
      tokenA,
      tokenB,
      amountADesired,
      amountBDesired,
      amountAMin,
      amountBMin,
      to,
      deadline
    );
  }

  function pledge(address pair, uint256 amount) public {
    require(pair == _v2Pair_usdt || pair == _v2Pair_9419, "invalid pair");

    updateTime();

    address uid = msg.sender;
    IBEP20(pair).transferFrom(uid, address(this), amount);

    _deposits[uid][pair] = amount;
    _depositTotal[pair] += amount;

    uint256 time;

    if (_time.add(24 hours).sub(_dividendCrondTime) > block.timestamp) {
      time = _time;
      _dividendIndex[uid][pair] += amount;
    } else {
      time = _time.add(_dividendCycly);
      _dividendTemp[uid][pair] += amount;
      _dividendTempTime[uid] = time;
    }
    if (_diviendTime[uid] == 0) {
      _diviendTime[uid] = time;
    }
  }

  function getAmountLPView(address uid) public view returns (uint256) {
    uint256 amountLP = 0;
    address[] memory pairList = new address[](2);
    pairList[0] = _v2Pair_usdt;
    pairList[1] = _v2Pair_9419;

    for (uint256 i = 0; i < pairList.length; i++) {
      address pair = pairList[i];
      uint256 lp = _deposits[uid][pair];
      uint256 balance = balanceOf(pair);
      uint256 total = IBEP20(pair).totalSupply();
      if (total > 0) {
        amountLP += lp.mul(balance).div(total);
      }
    }
    return amountLP;
  }

  function getAmountLP(address uid) public view returns (uint256) {
    uint256 amountLP = 0;
    address[] memory pairList = new address[](2);
    pairList[0] = _v2Pair_usdt;
    pairList[1] = _v2Pair_9419;

    for (uint256 i = 0; i < pairList.length; i++) {
      address pair = pairList[i];
      uint256 lp = _dividendIndex[uid][pair];
      if (_time > _dividendTempTime[uid]) {
        lp += _dividendTemp[uid][pair];
      }
      uint256 balance = balanceOf(pair);
      uint256 total = IBEP20(pair).totalSupply();
      if (total > 0) {
        amountLP += lp.mul(balance).div(total);
      }
    }
    return amountLP;
  }

  function getAmountLPTotal() public view returns (uint256) {
    return _balances[_v2Pair_usdt].add(_balances[_v2Pair_9419]);
  }

  function getAmountPledgeLPTotal() public view returns (uint256) {
    uint256 amountLP = 0;
    address[] memory pairList = new address[](2);
    pairList[0] = _v2Pair_usdt;
    pairList[1] = _v2Pair_9419;

    for (uint256 i = 0; i < pairList.length; i++) {
      address pair = pairList[i];
      uint256 lp = _depositTotal[pair];
      uint256 balance = balanceOf(pair);
      uint256 total = IBEP20(pair).totalSupply();
      if (total > 0) {
        amountLP += lp.mul(balance).div(total);
      }
    }
    return amountLP;
  }

  function hasDividend(address uid) public view returns (bool) {
    if (_diviendTime[uid] == 0) return false;
    if (_balances[address(_smartVault_dividend_2)] == 0) return false;
    if (_diviendTime[uid].add(_dividendCycly) > block.timestamp) return false;
    return true;
  }

  function dividendAmount(address uid) public view returns (uint256) {
    if (!hasDividend(uid)) return 0;
    return dividendAmountBase(uid);
  }

  function dividendAmountBase(address uid) public view returns (uint256) {
    uint256 amountLP = getAmountLP(uid);
    if (amountLP == 0) return 0;
    uint256 amountLPTotal = getAmountPledgeLPTotal();
    if (amountLPTotal == 0) return 0;
    return _diviendBase.mul(amountLP).div(amountLPTotal);
  }

  event Dividend(address uid, address pid, uint256 amount, uint256 inviteBonus);

  function dividend() external {
    updateTime();
    address uid = msg.sender;
    require(hasDividend(uid), "no dividend");

    uint256 amount = dividendAmount(uid);
    _smartVault_dividend_2.transfer(address(this), uid, amount);
    _dividendTotal[uid] += amount;

    if (_users[uid].pid != address(0)) {
      uint256 dividendInvite = dividendAmountBase(_users[uid].pid);
      if (dividendInvite > 0) {
        uint256 bonusBase = dividendInvite > amount ? amount : dividendInvite;
        uint256 inviteBonus = bonusBase.mul(_inviteRateLP).div(RBASE);
        if (inviteBonus > 0) {
          _smartVault_dividend_1.transfer(
            address(this),
            _users[uid].pid,
            inviteBonus
          );
          _inviteTotal[_users[uid].pid] += inviteBonus;
          emit Dividend(uid, _users[uid].pid, amount, inviteBonus);
        }
      }
    }

    address[] memory pairList = new address[](2);
    pairList[0] = _v2Pair_usdt;
    pairList[1] = _v2Pair_9419;
    for (uint256 i = 0; i < pairList.length; i++) {
      address pair = pairList[i];
      if (_time > _dividendTempTime[uid]) {
        _dividendIndex[uid][pair] += _dividendTemp[uid][pair];
      }
    }
    _diviendTime[uid] = _time;
  }

  function hasWithdraw(address uid) public view returns (bool) {
    return _deposits[uid][_v2Pair_usdt].add(_deposits[uid][_v2Pair_9419]) > 0;
  }

  function withdraw() public {
    address uid = msg.sender;
    require(hasWithdraw(uid), "no LP");

    address[] memory pairList = new address[](2);
    pairList[0] = _v2Pair_usdt;
    pairList[1] = _v2Pair_9419;

    _diviendTime[uid] = 0;
    for (uint256 i = 0; i < pairList.length; i++) {
      address pair = pairList[i];
      uint256 amount = _deposits[uid][pair];
      if (amount > 0) {
        _deposits[uid][pair] = 0;
        _dividendIndex[uid][pair] = 0;
        _dividendTemp[uid][pair] = 0;
        _depositTotal[pair] -= amount;
        IBEP20(pair).transfer(uid, amount);
      }
    }
  }

  function getParams(
    address uid
  )
    public
    view
    returns (
      uint256 totalLP,
      uint256 myLP,
      uint256 pledgeTotalLP,
      uint256 amount,
      uint256 dividendTotal,
      uint256 inviteTotal,
      bool isDividend,
      bool isWithdraw
    )
  {
    totalLP = getAmountLPTotal();
    myLP = getAmountLPView(uid);
    pledgeTotalLP = getAmountPledgeLPTotal();
    amount = dividendAmount(uid);
    dividendTotal = _dividendTotal[uid];
    inviteTotal = _inviteTotal[uid];
    isDividend = hasDividend(uid);
    isWithdraw = hasWithdraw(uid);
  }

  function isRobot(address _uid) external view returns (bool) {
    return _robots[_uid];
  }

  function swapTime() external view returns (uint256) {
    return _swapTime;
  }

  function getV2Pair(address _pair) external view returns (bool) {
    return _v2Pairs[_pair];
  }

  function getMarketing()
    external
    view
    returns (
      address smart_invite,
      address smart_dividend_1,
      address smart_dividend_2,
      address smart_usdt,
      address smart_9419,
      address smart_transit
    )
  {
    return (
      address(_smartVault_invite),
      address(_smartVault_dividend_1),
      address(_smartVault_dividend_2),
      address(_smartVault_usdt),
      address(_smartVault_9419),
      address(_smartVault_transit)
    );
  }

  function setInviteRate(uint256 rate, uint256 rateLP) external onlyOwner {
    require(rate > 0, "invalid parameter: rate");
    require(rateLP > 0, "invalid parameter: rateLP");
    _inviteRate = rate;
    _inviteRateLP = rateLP;
  }

  function setDividendRate(uint256 rate) external onlyOwner {
    require(rate > 0, "invalid parameter: rate");
    _dividendRate = rate;
  }

  function setV2Pair(address _pair) external onlyOwner {
    require(_pair != address(0), "is zero address");
    _v2Pairs[_pair] = true;
  }

  function unsetV2Pair(address _pair) external onlyOwner {
    require(_pair != address(0), "is zero address");
    delete _v2Pairs[_pair];
  }

  function setBurnNot(address uid) external onlyOwner {
    _burnNot[uid] = true;
  }

  function unsetBurnNot(address uid) external onlyOwner {
    _burnNot[uid] = false;
  }

  function setBurnAssignRate(uint256 rate1, uint256 rate2) external onlyOwner {
    require(rate1 > 0, "invalid parameter: rate1");
    require(rate2 > 0, "invalid parameter: rate2");
    _burnAssignRateDividend = rate1;
    _burnAssignRatePool = rate2;
  }

  function setRobot(address _uid) external onlyOwner {
    require(!_robots[_uid]);
    _robots[_uid] = true;
  }

  function unsetRobot(address _uid) external onlyOwner {
    require(_robots[_uid]);
    _robots[_uid] = false;
  }

  function setExcluded(address uid) external onlyOwner {
    _excluded[uid] = true;
  }

  function unsetExcluded(address uid) external onlyOwner {
    _excluded[uid] = false;
  }

  function setMaxTxUSDTLP(uint256 amount) external onlyOwner {
    _maxTxUSDTLP = amount;
  }

  function setPullRate(uint256 rate) external onlyOwner {
    require(rate > 0, "invalid parameter: rate");
    _pullRate = rate;
  }

  function setPullAssignRate(uint256 rate) external onlyOwner {
    require(rate > 0, "invalid parameter: rate");
    _pullAssignRate = rate;
  }

  function setDividendCycle(uint256 sec) external onlyOwner {
    require(sec > 0, "invalid parameter: sec");
    _dividendCycly = sec;
  }

  function setDividendCrondTime(uint256 sec) external onlyOwner {
    require(sec > 0, "invalid parameter: sec");
    _dividendCrondTime = sec;
  }

  function setBurnCycle(uint256 sec) external onlyOwner {
    require(sec > 0, "invalid parameter: sec");
    _burnCycle = sec;
  }

  function setBurnCycleLP(uint256 sec) external onlyOwner {
    require(sec > 0, "invalid parameter: sec");
    _burnCycleLP = sec;
  }

  function setBurnRate(uint256 rate) external onlyOwner {
    require(rate > 0, "invalid parameter: rate");
    _burnRate = rate;
  }

  function setBurnRateLP(uint256 rate) external onlyOwner {
    require(rate > 0, "invalid parameter: rate");
    _burnRateLP = rate;
  }

  function setSwapTime(uint256 time) external onlyOwner {
    require(time >= block.timestamp, "invalid parameter: time");
    _swapTime = time;
  }

  function setMaxDividend(uint256 max) external onlyOwner {
    require(_maxDividend > 0, "invalid parameter");
    require(_maxDividend != max);
    _maxDividend = max;
  }

  function getUser(address uid) external view returns (User memory) {
    return _users[uid];
  }

  function getFeeLP() external view returns (uint256 usdt) {
    return _feeLP_usdt;
  }

  function getPairList() external view returns (address usdt, address t9419) {
    usdt = _v2Pair_usdt;
    t9419 = _v2Pair_9419;
  }

  function getBalanceLP(
    address uid,
    address pair
  ) external view returns (uint256) {
    return IBEP20(pair).balanceOf(uid);
  }

  function checkLiquidity() public view returns (bool usdt, bool t9419) {
    usdt = address(_USDT) < address(this);
    t9419 = address(_T9419) < address(this);
  }

  function inviteList(
    address uid,
    uint256 page,
    uint256 pageSize
  ) external view returns (User[] memory user, uint256 total) {
    total = _inviters[uid].length;
    if (total == 0) return (user, total);
    page = page < 1 ? 1 : page;
    pageSize = pageSize > total ? total : pageSize;
    uint256 start = (page.sub(1)).mul(pageSize);
    uint256 end = start.add(pageSize);
    if (end > total) end = total;
    user = new User[](end.sub(start));
    for (uint256 i = start; i < end; i++) {
      user[i.sub(start)] = _inviters[uid][i];
    }
  }
}