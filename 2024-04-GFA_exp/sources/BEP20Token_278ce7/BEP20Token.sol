/**
 *Submitted for verification at BscScan.com on 2024-03-30
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;


contract Context {
  // Empty internal constructor, to prevent people from mistakenly deploying
  // an instance of this contract, which should be used via inheritance.
  constructor () { }

  function _msgSender() internal view returns (address) {
    return msg.sender;
  }

  function _msgData() internal view returns (bytes memory) {
    this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
    return msg.data;
  }
}

library SafeMath {
    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 c = a + b;
        require(c >= a, "SafeMath: addition overflow");

        return c;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return sub(a, b, "SafeMath: subtraction overflow");
    }

    function sub(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b <= a, errorMessage);
        uint256 c = a - b;

        return c;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) {
            return 0;
        }

        uint256 c = a * b;
        require(c / a == b, "SafeMath: multiplication overflow");

        return c;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return div(a, b, "SafeMath: division by zero");
    }

    function div(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b > 0, errorMessage);
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold

        return c;
    }

    function mod(uint256 a, uint256 b) internal pure returns (uint256) {
        return mod(a, b, "SafeMath: modulo by zero");
    }

    function mod(
        uint256 a,
        uint256 b,
        string memory errorMessage
    ) internal pure returns (uint256) {
        require(b != 0, errorMessage);
        return a % b;
    }
}

contract Ownable is Context {
  address private _owner;

  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

  /**
   * @dev Initializes the contract setting the deployer as the initial owner.
   */
  constructor () {
    address msgSender = _msgSender();
    _owner = msgSender;
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
  // function transferOwnership(address newOwner) public onlyOwner {
  //   _transferOwnership(newOwner);
  // }

  /**
   * @dev Transfers ownership of the contract to a new account (`newOwner`).
   */
  // function _transferOwnership(address newOwner) internal {
  //   require(newOwner != address(0), "Ownable: new owner is the zero address");
  //   emit OwnershipTransferred(_owner, newOwner);
  //   _owner = newOwner;
  // }
}


interface ISwapRouter {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

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

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface ISwapFactory {
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
}

interface ISwapPair {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function token0() external view returns (address);

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function skim(address to) external;
    
    function sync() external;
}

interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

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
    ) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

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
    function approve(address spender, uint256 amount) external returns (bool);

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
    ) external returns (bool);

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
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

contract Reward is Context {
    using SafeMath for uint256;
    struct RewardData {
        address reward;
        uint256 amount;
        uint256 remain;
        uint256 price;
        uint256 timestemp;
    }

    struct RewardHistory {
      uint256 amount;
      uint256 goldAmount;
      uint256 coinAmount;
      uint256 price;
      uint256 timesptemp;
    }

    uint256 _totalMineCnt = 0;
    uint256 _totalRemainCnt = 0;
    uint256 _mineDaliyRatio;
    uint256 _fixMineCoinRatio = 30;
    uint256 _decimals;
    mapping (address => RewardData[]) reward;
    address[] rewardKeys;
    mapping (address => uint256) waitRelease;
    mapping (address => RewardHistory[]) history;
    mapping (address => uint256) historyTotal;

    address _mainPair;

    function init(uint256 mineDaliyRatio, uint256 decimals, address mainPair) public {
        _mineDaliyRatio = mineDaliyRatio;
        _decimals = decimals;
        _mainPair = mainPair;
    }

    function setReward(address rewardSender, uint256 amount, uint256 remain, uint256 price) public {
        if(reward[rewardSender].length == 0) {
            rewardKeys.push(rewardSender);
        }

        reward[rewardSender].push(RewardData(rewardSender, amount, remain, price, block.timestamp));
        _totalRemainCnt += remain;
    }


    event CoinReward(address adr, uint256 amount, uint256 price, uint256 sameCoin, uint256 finxMineCoin);
    function generateReward(uint256 coinPrice) public{
        coinPrice = coinPrice == 0 ? 1 * 10 ** _decimals : coinPrice;
        for (uint i = 0; i < rewardKeys.length; i++) 
        {
            for (uint j = 0; j < reward[rewardKeys[i]].length; j++) 
            {
                if (reward[rewardKeys[i]][j].remain == 0) {
                    continue;
                }

                uint256 pawnPrice = reward[rewardKeys[i]][j].price;
                uint256 targetRelease = reward[rewardKeys[i]][j].amount.mul(_mineDaliyRatio) / 100;
                uint256 fixMineCoin = targetRelease.mul(_fixMineCoinRatio).div(100);
                uint256 sameCoinValue = (((targetRelease - fixMineCoin) * pawnPrice).div(coinPrice));

                uint256 release = sameCoinValue + fixMineCoin;
                if (reward[rewardKeys[i]][j].remain < release) {
                    release = reward[rewardKeys[i]][j].remain;
                }

                if(waitRelease[rewardKeys[i]] != 0) {
                  waitRelease[rewardKeys[i]] += release;
                } else {
                  waitRelease[rewardKeys[i]] = release;
                }

                if (historyTotal[rewardKeys[i]] != 0) {
                    historyTotal[rewardKeys[i]] += release;
                } else {
                    historyTotal[rewardKeys[i]] = release;
                }
                reward[rewardKeys[i]][j].remain = reward[rewardKeys[i]][j].remain - release;
                history[rewardKeys[i]].push(RewardHistory(release, sameCoinValue, fixMineCoin, coinPrice, block.timestamp));
                _totalMineCnt += release;
                emit CoinReward(rewardKeys[i], release, coinPrice, sameCoinValue, fixMineCoin);
            }
        }
    }

    function releaseCoin(address sender) public returns(uint256) {
        uint256 release = waitRelease[sender];
        waitRelease[sender] = 0;
        _totalRemainCnt -= release;
        return release;
    }

    function getWaitReleaseCoin(address sender) public view returns(uint256) {
        return waitRelease[sender];
    }

    function getRewardList(address sender) public view returns(RewardData[] memory ){
        return reward[sender];
    }

    function getRewardAddressList() public view returns(address[] memory) {
        return rewardKeys;
    }

    function getHistory(address sender) public view returns(RewardHistory[] memory) {
        return history[sender];
    }

    function getHistoryMineTotal(address sender) public view returns(uint256) {
        return historyTotal[sender];
    }

    function getTotalMineCnt() external view returns(uint256) {
        return _totalMineCnt;
    }

    function getTotalRemainCnt() external view returns(uint256) {
      return _totalRemainCnt;
    }

}

contract TokenDistributor {
    constructor(address token) {
        IERC20(token).approve(msg.sender, uint256(~uint256(0)));
    }
}

 
contract BEP20Token is Context, IERC20, Ownable {
    using SafeMath for uint256;

    mapping (address => uint256) private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    
    uint256 private _totalSupply;
    uint8 private _decimals;
    string private _symbol;
    string private _name;

    Reward private reward;
    uint256 private releaseAmount = 10000;
    uint256 private _pawnMineMul = 150;

    ISwapRouter private _swapRouter;
    address private _mainPair;
    // address private ROUTER_ADDRESS = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address private ROUTER_ADDRESS = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private contractAddress;
    mapping(address => bool) private _swapPairList;

    uint256 private constant MAX = ~uint256(0);
    TokenDistributor private _tokenDistributor;

    uint256 private lastExchangeTime;
    uint256 private dailyExchangeVolume;
    uint256 private dailyExchangePawnVolume;
    uint256 private PawnVolumeRate = 30;
    uint256 private mineFrequency = 86400;
    uint256 private resetExchangeVolumnFrequency = 86400;

    uint256 private buy_fee = 3;
    uint256 private sale_fee = 3;
    address private USDT_TOKEN;
    address private TARGET_ADDRESS;
    address private FEE_ADDRESS;
    address private RECOMMEND_ADDRESS;
    address private BURN_ADDRESS;

    uint256 PawnBurnRatio = 84;
    uint256 mineDaliyRatio = 2;
    uint256 lastMineTime;

    uint256 lastLpBurnTime;
    uint256 lpBurnRate = 1;
    uint256 lpBurnTarget = 1980000;
    uint256 lpBurnFrequency = 14400;
    
    mapping(address => bool) private _blackList;

    bool hasStart = false;
    constructor(
          string[] memory symbolParam, 
          address[] memory adr
            ) {

        _name = symbolParam[0];
        _symbol = symbolParam[1];
        _decimals = 18;
        _totalSupply = 9980000000000000000000000;
        contractAddress = address(this);

        USDT_TOKEN = adr[0];
        TARGET_ADDRESS = adr[1];
        FEE_ADDRESS = adr[2];
        RECOMMEND_ADDRESS = adr[3];
        BURN_ADDRESS = adr[4];

        dailyExchangeVolume = 0;
        dailyExchangePawnVolume = 0;

        uint256 minePool = 8000000000000000000000000;
        uint256 constractPool = _totalSupply - minePool;

        _tokenDistributor = new TokenDistributor(USDT_TOKEN);

        _balances[msg.sender] = constractPool;
        _balances[address(_tokenDistributor)] = minePool;

        _swapRouter = ISwapRouter(ROUTER_ADDRESS);
        IERC20(USDT_TOKEN).approve(address(_swapRouter), MAX);
        _allowances[address(this)][address(_swapRouter)] = MAX;

        ISwapFactory swapFactory = ISwapFactory(_swapRouter.factory());
        _mainPair = swapFactory.createPair(address(this), USDT_TOKEN);
        _swapPairList[_mainPair] = true;

        reward = new Reward();
        reward.init(mineDaliyRatio, _decimals, _mainPair);

        emit Transfer(address(0), msg.sender, constractPool);
        emit Transfer(address(0), address(_tokenDistributor), minePool);
    }

    function getTotalMineCnt() public view returns(uint256) {
        return reward.getTotalMineCnt();
    }

    function getTotalRemainCnt() public view returns(uint256) {
      return reward.getTotalRemainCnt();
    }

    function getWaitRelease(address adr) public view returns (uint256) {
        return reward.getWaitReleaseCoin(adr);
    }

    function getRewardList(address adr) public view returns(Reward.RewardData[] memory ){ 
        return reward.getRewardList(adr);
    }

    function getRewardAddressList() public view returns(address[] memory ){ 
        return reward.getRewardAddressList();
    }
    
    function getRewardHistory(address adr) public view returns (Reward.RewardHistory[] memory) {
        return reward.getHistory(adr);
    }

    function getRewardHisotryTotal(address adr) public view returns (uint256) {
        return reward.getHistoryMineTotal(adr);
    }
    
    function getPawnVolumn() public view returns(uint256) {
        return dailyExchangePawnVolume;
    }
    
    function getLastMineTime() public view returns(uint256) {
        return lastMineTime;
    }

    function getLastExchangeTime() public view returns(uint256) {
        return lastExchangeTime;
    }

    function launch(uint256 startState) public onlyOwner {
        lastExchangeTime = block.timestamp;
        lastMineTime = block.timestamp;
        lastLpBurnTime = block.timestamp;
        hasStart = startState == 1;
    }

    function getPrice() public view returns(uint256 _price) {
      return _getPrice();
    }

    function _mineCoin() internal {
      if (_balances[address(_tokenDistributor)] <= 0) {
        return;
      }
      
      lastMineTime = block.timestamp;
      reward.generateReward(_getPrice());
    }

    function _getPrice() internal view returns(uint256 _price) {
      address t0 = ISwapPair(address(_mainPair)).token0();
      (uint r0, uint r1, ) = ISwapPair(address(_mainPair)).getReserves();

      if (r0 > 0 && r1 > 0) {
        if (t0 == address(this)) {
          _price = r1 * 10 ** _decimals / r0;
        } else {
          _price = r0 * 10 ** _decimals / r1;
        }
      }
    }

  function setBlack(address black, bool enable) external onlyOwner {
    _blackList[black] = enable;
  }

  function setFee(uint256 buyFee, uint256 saleFee) external onlyOwner {
    buy_fee = buyFee;
    sale_fee = saleFee;
  }

  function setTimes(uint256 mineTime, uint256 exchangeTime,  uint256 burnTime) public onlyOwner {
    if (mineTime != 0) {
      mineFrequency = mineTime;
    }

    if (exchangeTime != 0) {
      resetExchangeVolumnFrequency = exchangeTime;
    }

    if (burnTime != 0) {
      lpBurnFrequency = burnTime;
    }
  }

  function setRates(uint256 pawnBurnRatio, uint256 minRatio, uint256 pawnRatio, uint256 lpBurnRatio) external onlyOwner {
    if (pawnBurnRatio != 0) {
      PawnBurnRatio = pawnBurnRatio;
    }

    if (minRatio != 0) {
      mineDaliyRatio = minRatio;
    }

    if (pawnRatio != 0) {
      PawnVolumeRate = pawnRatio;
    }

    if (lpBurnRatio != 0) {
      lpBurnRate = lpBurnRatio;
    }
  }

  
  function getRates() external view returns(uint256[] memory) {
    uint256[] memory ratesArr = new uint256[](6);
    ratesArr[0] = PawnBurnRatio;
    ratesArr[1] = mineDaliyRatio;
    ratesArr[2] = PawnVolumeRate;
    ratesArr[3] = lpBurnRate;
    ratesArr[4] = buy_fee;
    ratesArr[5] = sale_fee;

    return ratesArr;
  }

  function getTimes() external view returns(uint256[] memory) {
    uint256[] memory timesArr = new uint256[](3);
    timesArr[0] = mineFrequency;
    timesArr[1] = resetExchangeVolumnFrequency;
    timesArr[2] = lpBurnFrequency;

    return timesArr;
  }

  function getLastTimes() external view returns(uint256[] memory) {
    uint256[] memory lastTimes = new uint256[](3);
    lastTimes[0] = lastExchangeTime;
    lastTimes[1] = lastLpBurnTime;
    lastTimes[2] = lastMineTime;

    return lastTimes;
  }

  function isBlackAddr(address addr) external view returns(bool) {
    return _blackList[addr];
  }

  /**
   * @dev Returns the bep token owner.
   */
  function getOwner() external view returns (address) {
    return owner();
  }

  /**
   * @dev Returns the token decimals.
   */
  function decimals() external view returns (uint8) {
    return _decimals;
  }

  /**
   * @dev Returns the token symbol.
   */
  function symbol() external view returns (string memory) {
    return _symbol;
  }

  /**
  * @dev Returns the token name.
  */
  function name() external view returns (string memory) {
    return _name;
  }

  /**
   * @dev See {BEP20-totalSupply}.
   */
  function totalSupply() external view override  returns (uint256) {
    return _totalSupply;
  }

  /**
   * @dev See {BEP20-balanceOf}.
   */
  function balanceOf(address account) external view override returns (uint256) {
    return _balances[account];
  }

  /**
   * @dev See {BEP20-transfer}.
   *
   * Requirements:
   *
   * - `recipient` cannot be the zero address.
   * - the caller must have a balance of at least `amount`.
   */
  function transfer(address recipient, uint256 amount) external override returns (bool) {
    _transfer(_msgSender(), recipient, amount);
    return true;
  }

  /**
   * @dev See {BEP20-allowance}.
   */
  function allowance(address owner, address spender) external view override returns (uint256) {
    return _allowances[owner][spender];
  }

  /**
   * @dev See {BEP20-approve}.
   *
   * Requirements:
   *
   * - `spender` cannot be the zero address.
   */
  function approve(address spender, uint256 amount) external override returns (bool) {
    _approve(_msgSender(), spender, amount);
    return true;
  }

  /**
   * @dev See {BEP20-transferFrom}.
   *
   * Emits an {Approval} event indicating the updated allowance. This is not
   * required by the EIP. See the note at the beginning of {BEP20};
   *
   * Requirements:
   * - `sender` and `recipient` cannot be the zero address.
   * - `sender` must have a balance of at least `amount`.
   * - the caller must have allowance for `sender`'s tokens of at least
   * `amount`.
   */
  function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
    _transfer(sender, recipient, amount);
    _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "BEP20: transfer amount exceeds allowance"));
    return true;
  }

  /**
   * @dev Atomically increases the allowance granted to `spender` by the caller.
   *
   * This is an alternative to {approve} that can be used as a mitigation for
   * problems described in {BEP20-approve}.
   *
   * Emits an {Approval} event indicating the updated allowance.
   *
   * Requirements:
   *
   * - `spender` cannot be the zero address.
   */
  function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
    _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
    return true;
  }

  /**
   * @dev Atomically decreases the allowance granted to `spender` by the caller.
   *
   * This is an alternative to {approve} that can be used as a mitigation for
   * problems described in {BEP20-approve}.
   *
   * Emits an {Approval} event indicating the updated allowance.
   *
   * Requirements:
   *
   * - `spender` cannot be the zero address.
   * - `spender` must have allowance for the caller of at least
   * `subtractedValue`.
   */
  function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
    _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "BEP20: decreased allowance below zero"));
    return true;
  }

  /**
   * @dev Moves tokens `amount` from `sender` to `recipient`.
   *
   * This is internal function is equivalent to {transfer}, and can be used to
   * e.g. implement automatic token fees, slashing mechanisms, etc.
   *
   * Emits a {Transfer} event.
   *
   * Requirements:
   *
   * - `sender` cannot be the zero address.
   * - `recipient` cannot be the zero address.
   * - `sender` must have a balance of at least `amount`.
   */
  function _transfer(address sender, address recipient, uint256 amount) internal {
    require(sender != address(0), "BEP20: transfer from the zero address");
    require(recipient != address(0), "BEP20: transfer to the zero address");
    bool isBlack = _blackList[sender] || _blackList[recipient];
    require(!isBlack, "black");
    _balances[sender].sub(amount, "BEP20: transfer amount exceeds balance");


    if (!hasStart) {
      _basicTransfer(sender, recipient, amount);
      return;
    }

    if(_swapPairList[sender] || _swapPairList[recipient]) {
        uint256 fee;
        if (_swapPairList[recipient]) {
          if (block.timestamp >= lastLpBurnTime + lpBurnFrequency) {
            autoBurnLiquidityPairTokens();
          }
          fee = sale_fee;
        } else {
          fee = buy_fee;
        }

        if (_swapPairList[sender]) {
          uint256 pawnVolumnAmount = amount.mul(PawnVolumeRate).div(100);
          if(block.timestamp >= lastExchangeTime + resetExchangeVolumnFrequency) {
            lastExchangeTime = block.timestamp;
            dailyExchangeVolume = pawnVolumnAmount;
            dailyExchangePawnVolume = pawnVolumnAmount;
          } else {
            dailyExchangeVolume = dailyExchangeVolume + pawnVolumnAmount;
            dailyExchangePawnVolume = dailyExchangePawnVolume + pawnVolumnAmount;
          }
        }

        uint256 feeAmount = amount.mul(fee).div(100);

        _tokenOperation();
        _basicTransfer(sender, recipient, amount.sub(feeAmount));
        _basicTransfer(sender, FEE_ADDRESS, feeAmount);
    } else if (recipient == contractAddress) {
      if (amount == releaseAmount) {
        uint256 waitRelease = reward.getWaitReleaseCoin(sender);
        uint256 poolBalance =  _balances[address(_tokenDistributor)];
        if (poolBalance < waitRelease) {
            waitRelease = poolBalance;
        }

        reward.releaseCoin(sender);
        _basicTransfer(address(_tokenDistributor), sender, waitRelease);
        _basicTransfer(sender, recipient, amount);
      } else {
        _toPawn(amount);
      } 
    } else {
      _basicTransfer(sender, recipient, amount);
    }
  }

  function _tokenOperation() internal  {
    if (block.timestamp >= lastMineTime + mineFrequency) {   
      _mineCoin();
    }
  }

  function _basicTransfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        _balances[sender] -= amount;
        _balances[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }

  /** @dev Creates `amount` tokens and assigns them to `account`, increasing
   * the total supply.
   *
   * Emits a {Transfer} event with `from` set to the zero address.
   *
   * Requirements
   *
   * - `to` cannot be the zero address.
   */
  function _mint(address account, uint256 amount) internal {
    require(account != address(0), "BEP20: mint to the zero address");

    _totalSupply = _totalSupply.add(amount);
    _balances[account] = _balances[account].add(amount);
    emit Transfer(address(0), account, amount);
  }

  /**
   * @dev Sets `amount` as the allowance of `spender` over the `owner`s tokens.
   *
   * This is internal function is equivalent to `approve`, and can be used to
   * e.g. set automatic allowances for certain subsystems, etc.
   *
   * Emits an {Approval} event.
   *
   * Requirements:
   *
   * - `owner` cannot be the zero address.
   * - `spender` cannot be the zero address.
   */
  function _approve(address owner, address spender, uint256 amount) internal {
    require(owner != address(0), "BEP20: approve from the zero address");
    require(spender != address(0), "BEP20: approve to the zero address");

    _allowances[owner][spender] = amount;
    emit Approval(owner, spender, amount);
  }


  event AutoNukeLP();
  function autoBurnLiquidityPairTokens() internal {
      lastLpBurnTime = block.timestamp;

      uint256 liquidityPairBalance = _balances[_mainPair];
      if(!_isBurn()){
          return;
      }

      uint256 amountToBurn = liquidityPairBalance * lpBurnRate / 1000;
      if (amountToBurn > 0) {
          _basicTransfer(
            _mainPair,
            address(0xdead),
            amountToBurn
          );

          //sync price since this is not in a swap transaction!
          ISwapPair pair = ISwapPair(_mainPair);
          pair.sync();
          emit AutoNukeLP();
          return ;
      }

  }


  function _isBurn() internal view returns(bool) {
    return _totalSupply - _balances[address(0xdead)] > lpBurnTarget * 10 ** _decimals;
  }

  event Pawn(address sender, uint256 amount, uint256 volumn);
  function _toPawn(uint256 amount) internal {
      uint256 mineCoinCnt = amount * _pawnMineMul / 100;
      dailyExchangePawnVolume = dailyExchangePawnVolume.sub(amount, "exchange not enough");
      uint256 price = _getPrice();
      address sender = msg.sender;
      uint256 burnCoin = amount.mul(PawnBurnRatio).div(100);
      if (_isBurn()) {
        _basicTransfer(sender, address(0xdead), burnCoin);
      } else {
        _basicTransfer(sender, BURN_ADDRESS, burnCoin);
      }
      _basicTransfer(sender, RECOMMEND_ADDRESS, amount - burnCoin);
      reward.setReward(sender, amount, mineCoinCnt, price);

      emit Pawn(sender, amount, dailyExchangePawnVolume);
  }
}