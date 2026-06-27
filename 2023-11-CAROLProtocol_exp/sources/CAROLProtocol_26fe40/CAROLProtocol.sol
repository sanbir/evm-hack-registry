// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address) external;
}

interface IUniswapV2Router01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

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

interface IERC20 {
    
    event Transfer(address indexed from, address indexed to, uint256 value);

    
    event Approval(address indexed owner, address indexed spender, uint256 value);

    
    function totalSupply() external view returns (uint256);

    
    function balanceOf(address account) external view returns (uint256);

    
    function transfer(address to, uint256 amount) external returns (bool);

    
    function allowance(address owner, address spender) external view returns (uint256);

    
    function approve(address spender, uint256 amount) external returns (bool);

    
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC20Metadata is IERC20 {
    
    function name() external view returns (string memory);

    
    function symbol() external view returns (string memory);

    
    function decimals() external view returns (uint8);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
        return true;
    }

    
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            
            
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        unchecked {
            
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            
            _totalSupply -= amount;
        }

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    
    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}
}

abstract contract ERC20Burnable is Context, ERC20 {
    
    function burn(uint256 amount) public virtual {
        _burn(_msgSender(), amount);
    }

    
    function burnFrom(address account, uint256 amount) public virtual {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    
    constructor() {
        _transferOwnership(_msgSender());
    }

    
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    
    function owner() public view virtual returns (address) {
        return _owner;
    }

    
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract CAROLToken is ERC20, ERC20Burnable, Ownable {

  address public immutable UNISWAP_ROUTER_ADDRESS;
  address public LP_TOKEN_ADDRESS;

  address public mainContractAddress;

  constructor(address uniswapRouterAddress) ERC20("CAROL", "CAROL") {
    UNISWAP_ROUTER_ADDRESS = uniswapRouterAddress;

    _mint(msg.sender, 1_000_000 * 10 ** decimals()); 
  }

  function setMainContractAddress(address contractAddress) external onlyOwner {
    require(mainContractAddress == address(0), "Main contract address already configured");

    mainContractAddress = contractAddress;
  }

  function mint(address to, uint256 amount) public {
    require(msg.sender == mainContractAddress, "Mint: only main contract can mint tokens");

    _mint(to, amount);
  }

  function setLPTokenAddress(address lpTokenAddress) external onlyOwner {
    require(LP_TOKEN_ADDRESS == address(0), "Owner: LP token address already configured");

    LP_TOKEN_ADDRESS = lpTokenAddress;
  }

  bool public buyLocked = true;

  function unlockBuy() external onlyOwner {
    buyLocked = false;
  }

  function lockBuy() external onlyOwner {
    buyLocked = true;
  }

  function _beforeTokenTransfer(address from, address to, uint256 ) internal view override {
    if (LP_TOKEN_ADDRESS == address(0) || !buyLocked) {
      return;
    }

    if (from == LP_TOKEN_ADDRESS || from == UNISWAP_ROUTER_ADDRESS) {
      require(
           to == mainContractAddress 
        || to == UNISWAP_ROUTER_ADDRESS 
        || to == LP_TOKEN_ADDRESS 
        || to == address(0), 
        "Transfer: only main contract can buy tokens"
      );
    }
  }

}

library Constants {

  uint8 public constant BONDS_LIMIT = 100;
  uint256 public constant MIN_BOND_ETH = 0.001 ether;
  uint256 public constant MIN_BOND_TOKENS = 100 ether;

  uint256 public constant STAKING_REWARD_PERCENT = 200; 
  uint256 public constant STAKING_REWARD_LIMIT_PERCENT = 15000; 

  address public constant WRAPPED_ETH = 0x4200000000000000000000000000000000000006;

  

  uint256 constant public PERCENTS_DIVIDER = 10000;

  uint256 public constant GLOBAL_LIQUIDITY_BONUS_STEP_ETH = 25 ether;
  uint256 public constant GLOBAL_LIQUIDITY_BONUS_STEP_PERCENT = 10; 
  uint256 public constant GLOBAL_LIQUIDITY_BONUS_LIMIT_PERCENT = 10000; 

  uint256 public constant USER_HOLD_BONUS_STEP = 1 days;
  uint256 public constant USER_HOLD_BONUS_STEP_PERCENT = 5; 
  uint256 public constant USER_HOLD_BONUS_LIMIT_PERCENT = 200; 

  uint256 public constant LIQUIDITY_BONUS_STEP_ETH = 1 ether;
  uint256 public constant LIQUIDITY_BONUS_STEP_PERCENT = 10; 
  uint256 public constant LIQUIDITY_BONUS_LIMIT_PERCENT = 200; 

}

library Models {

  struct User {
    address upline;
    uint8 refLevel;
    uint8 bondsNumber;
    uint256 balance;
    uint256 totalInvested;
    uint256 liquidityCreated;
    uint256 totalRefReward;
    uint256 totalWithdrawn;
    uint256 refTurnover;
    uint256 lastActionTime;
    address[] referrals;
    uint256[10] refs;
    uint256[10] refsNumber;
  }

  struct Bond {
    uint256 amount;
    uint256 creationTime;

    uint256 freezePeriod;
    uint256 profitPercent;

    
    uint256 stakeAmount;
    uint256 stakeTime;
    uint256 collectedTime;
    uint256 collectedReward;
    uint256 stakingRewardLimit;

    bool isClosed;
  }

}

library Events {

  event NewBond(
    address indexed userAddress,
    uint8 indexed bondType,
    uint8 indexed bondIndex,
    uint256 amount,
    uint256 tokensAmount,
    bool isRebond,
    uint256 time
  );

  event ReBond(
    address indexed userAddress,
    uint8 indexed bondIndex,
    uint256 amount,
    uint256 tokensAmount,
    uint256 time
  );

  event StakeBond(
    address indexed userAddress,
    uint8 indexed bondIndex,
    uint256 amountToken,
    uint256 amountETH,
    uint256 time
  );

  event Transfer(
    address indexed userAddress,
    uint8 indexed bondIndex,
    uint256 amountToken,
    uint256 time
  );

  event Claim(
    address indexed userAddress,
    uint256 tokensAmount,
    uint256 time
  );

  event Sell(
    address indexed userAddress,
    uint256 tokensAmount,
    uint256 ethAmount,
    uint256 time
  );

  event NewUser(
    address indexed userAddress,
    address indexed upline,
    uint256 time
  );

  event RefPayout(
    address indexed investor,
    address indexed upline,
    uint256 indexed level,
    uint256 amount,
    uint256 time
  );

  event LiquidityAdded(
    uint256 amountToken,
    uint256 amountETH,
    uint256 liquidity,
    uint256 time
  );

}

contract CAROLProtocol is Ownable {

  mapping(address => Models.User) public users;
  mapping(address => mapping(uint8 => Models.Bond)) public bonds;

  address public immutable TOKEN_ADDRESS;
  address public immutable LP_TOKEN_ADDRESS;
  address public immutable UNISWAP_ROUTER_ADDRESS;

  address public immutable DEFAULT_UPLINE;

  uint256[] public REFERRAL_LEVELS_PERCENTS = [500, 700, 900, 1100, 1400, 1600, 1800, 2000];
  uint256[] public REFERRAL_LEVELS_MILESTONES = [0, 5 ether, 15 ether, 50 ether, 100 ether, 250 ether, 750 ether, 1500 ether];
  uint8 constant public REFERRAL_DEPTH = 10;
  uint8 constant public REFERRAL_TURNOVER_DEPTH = 5;

  uint256 private PRICE_BALANCER_PERCENT = 100; 

  uint256[5] public BOND_FREEZE_PERIODS = [
     30 days,
     20 days,
     10 days,
      5 days,
    100 days
  ];
  uint256[5] public BOND_FREEZE_PERCENTS = [
    3000, 
    2000, 
    1000, 
     500, 
       0  
  ];
  bool[5] public BOND_ACTIVATIONS = [
    true,
    false,
    false,
    false,
    false
  ];

  constructor(
    address uniswapRouterAddress,
    address CAROLTokenAddress,
    address lpTokenAddress,
    address defaultUpline
  ) {
    UNISWAP_ROUTER_ADDRESS = uniswapRouterAddress;
    TOKEN_ADDRESS = CAROLTokenAddress;
    LP_TOKEN_ADDRESS = lpTokenAddress;

    DEFAULT_UPLINE = defaultUpline;
  }

  receive() external payable {
    
  }

  function buy(address upline, uint8 bondType) external payable {
    require(bondType < 4 && BOND_ACTIVATIONS[bondType], "Buy: invalid bond type");
    require(users[msg.sender].bondsNumber < Constants.BONDS_LIMIT, "Buy: you have reached bonds limit");
    require(msg.value >= Constants.MIN_BOND_ETH, "Buy: min buy amount is 0.001 ETH");

    bool isNewUser = false;
    Models.User storage user = users[msg.sender];
    if (user.upline == address(0)) {
      isNewUser = true;
      if (upline == address(0) || upline == msg.sender || users[upline].bondsNumber == 0) {
        upline = DEFAULT_UPLINE;
      }
      user.upline = upline;

      if (upline != DEFAULT_UPLINE) {
        users[upline].referrals.push(msg.sender);
      }

      emit Events.NewUser(
        msg.sender, upline, block.timestamp
      );
    }

    uint256 refReward = distributeRefPayout(user, msg.value, isNewUser);
    uint256 adminFee = msg.value / 10;
    payable(owner()).transfer(adminFee);

    newBond(msg.sender, bondType, msg.value, msg.value - adminFee - refReward);
  }

  function distributeRefPayout(
    Models.User storage user,
    uint256 ethAmount, bool
    isNewUser
  ) private returns (uint256 refReward) {
    if (user.upline == address(0)) {
      return 0;
    }

    bool[] memory distributedLevels = new bool[](REFERRAL_LEVELS_PERCENTS.length);

    address current = msg.sender;
    address upline = user.upline;
    uint8 maxRefLevel = 0;
    for (uint256 i = 0; i < REFERRAL_DEPTH; i++) {
      if (upline == address(0)) {
        break;
      }

      uint256 refPercent = 0;
      if (i == 0) {
        refPercent = REFERRAL_LEVELS_PERCENTS[users[upline].refLevel];

        maxRefLevel = users[upline].refLevel;
        for (uint8 j = users[upline].refLevel; j >= 0; j--) {
          distributedLevels[j] = true;

          if (j == 0) {
            break;
          }
        }
      } else if (users[upline].refLevel > maxRefLevel && !distributedLevels[users[upline].refLevel]) {
        refPercent =
          REFERRAL_LEVELS_PERCENTS[users[upline].refLevel] - REFERRAL_LEVELS_PERCENTS[maxRefLevel];

        maxRefLevel = users[upline].refLevel;
        for (uint8 j = users[upline].refLevel; j >= 0; j--) {
          distributedLevels[j] = true;

          if (j == 0) {
            break;
          }
        }
      }

      uint256 amount = ethAmount * refPercent / Constants.PERCENTS_DIVIDER;
      if (amount > 0) {
        payable(upline).transfer(amount);
        users[upline].totalRefReward+= amount;
        refReward+= amount;

        emit Events.RefPayout(
          msg.sender, upline, i, amount, block.timestamp
        );
      }

      users[upline].refs[i]++;
      if (isNewUser) {
        users[upline].refsNumber[i]++;
      }

      current = upline;
      upline = users[upline].upline;
    }

    upline = user.upline;
    for (uint256 i = 0; i < REFERRAL_TURNOVER_DEPTH; i++) {
      if (upline == address(0)) {
        break;
      }

      updateReferralLevel(upline, ethAmount);

      upline = users[upline].upline;
    }

  }

  function updateReferralLevel(address _userAddress, uint256 _amount) private {
    users[_userAddress].refTurnover+= _amount;

    for (uint8 level = uint8(REFERRAL_LEVELS_MILESTONES.length - 1); level > 0; level--) {
      if (users[_userAddress].refTurnover >= REFERRAL_LEVELS_MILESTONES[level]) {
        users[_userAddress].refLevel = level;

        break;
      }
    }
  }

  function newBond(
    address userAddr,
    uint8 bondType,
    uint256 bondAmount,
    uint256 liquidityAmount
  ) private returns (uint8) {
    Models.User storage user = users[userAddr];
    Models.Bond storage bond  = bonds[userAddr][user.bondsNumber];

    bond.freezePeriod = BOND_FREEZE_PERIODS[bondType];
    bond.profitPercent = BOND_FREEZE_PERCENTS[bondType];
    bond.amount = bondAmount;
    bond.creationTime = block.timestamp;

    if (user.bondsNumber == 0) { 
      user.lastActionTime = block.timestamp;
    }

    user.bondsNumber++;
    user.totalInvested+= bondAmount;

    uint256 tokensAmount = 0;
    if (liquidityAmount > 0) {
      tokensAmount = getTokensAmount(liquidityAmount);
      CAROLToken(TOKEN_ADDRESS).mint(address(this), tokensAmount);
      CAROLToken(TOKEN_ADDRESS).increaseAllowance(UNISWAP_ROUTER_ADDRESS, tokensAmount);

      (uint256 amountToken, uint256 amountETH, uint256 liquidity) =
        IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS).addLiquidityETH {value: liquidityAmount} (
          TOKEN_ADDRESS,
          tokensAmount,
          0,
          0,
          address(this),
          block.timestamp + 5 minutes
        );

      emit Events.LiquidityAdded(
        amountToken, amountETH, liquidity, block.timestamp
      );
    }

    emit Events.NewBond(
      userAddr, bondType, user.bondsNumber - 1, bondAmount, tokensAmount, liquidityAmount == 0, block.timestamp
    );

    return user.bondsNumber - 1;
  }

  function stake(uint8 bondIdx) external payable {
    require(bondIdx < users[msg.sender].bondsNumber, "Stake: invalid bond index");
    require(!bonds[msg.sender][bondIdx].isClosed, "Stake: this bond already closed");
    require(bonds[msg.sender][bondIdx].stakeTime == 0, "Stake: this bond was already staked");

    Models.User storage user = users[msg.sender];
    Models.Bond storage bond  = bonds[msg.sender][bondIdx];

    uint256 ethAmount = bond.amount * (Constants.PERCENTS_DIVIDER + bond.profitPercent) / Constants.PERCENTS_DIVIDER;
    require(msg.value >= ethAmount, "Stake: invalid ETH amount"); 

    uint256 refReward = distributeRefPayout(user, msg.value, false);
    uint256 adminFee = msg.value / 10;
    payable(owner()).transfer(adminFee);

    uint256 tokensAmount = getTokensAmount(ethAmount);

    ethAmount = msg.value - refReward - adminFee;
    uint256 liquidityTokensAmount = getTokensAmount(ethAmount);

    CAROLToken(TOKEN_ADDRESS).mint(address(this), liquidityTokensAmount);
    CAROLToken(TOKEN_ADDRESS).increaseAllowance(UNISWAP_ROUTER_ADDRESS, liquidityTokensAmount);

    (uint256 amountToken, uint256 amountETH, uint256 liquidity) = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS).addLiquidityETH {value: ethAmount} (
      TOKEN_ADDRESS,
      liquidityTokensAmount,
      0,
      0,
      address(this),
      block.timestamp + 5 minutes
    );

    user.liquidityCreated+= msg.value;

    emit Events.LiquidityAdded(
      amountToken, amountETH, liquidity, block.timestamp
    );

    bond.stakeAmount = 2 * tokensAmount;
    bond.stakeTime = block.timestamp;
    bond.collectedTime = block.timestamp;
    bond.stakingRewardLimit = bond.stakeAmount * Constants.STAKING_REWARD_LIMIT_PERCENT / Constants.PERCENTS_DIVIDER;

    emit Events.StakeBond(
      msg.sender, bondIdx, tokensAmount, msg.value, block.timestamp
    );
  }

  
  function transfer(uint8 bondIdx) external {
    Models.Bond storage bond = bonds[msg.sender][bondIdx];

    require(bondIdx < users[msg.sender].bondsNumber, "Transfer: invalid bond index");
    require(!bond.isClosed, "Transfer: the bond is already closed");
    require(bond.stakeTime == 0, "Transfer: the bond is staked");
    require(
      block.timestamp >= bond.creationTime + bond.freezePeriod,
      "Transfer: this bond is still freeze"
    );

    uint256 tokensAmount =
      getTokensAmount(bond.amount * (Constants.PERCENTS_DIVIDER + bond.profitPercent) / Constants.PERCENTS_DIVIDER);

    users[msg.sender].balance+= tokensAmount;
    bond.isClosed = true;

    emit Events.Transfer(
      msg.sender, bondIdx, tokensAmount, block.timestamp
    );
  }

  function claim(uint256 tokensAmount) external {
    require(userBalance(msg.sender) >= tokensAmount, "Claim: insufficient balance");

    collect(msg.sender);
    Models.User storage user = users[msg.sender];
    require(user.balance >= tokensAmount, "Claim: insufficient balance");

    user.balance-= tokensAmount;
    user.lastActionTime = block.timestamp;
    CAROLToken(TOKEN_ADDRESS).mint(msg.sender, tokensAmount);

    emit Events.Claim(
      msg.sender, tokensAmount, block.timestamp
    );
  }

  
  function rebond(uint256 tokensAmount) external {
    require(users[msg.sender].bondsNumber < Constants.BONDS_LIMIT, "Rebond: you have reached bonds limit");
    require(tokensAmount >= Constants.MIN_BOND_TOKENS, "Rebond: min rebond amount is 100 CAROL");
    require(userBalance(msg.sender) >= tokensAmount, "Rebond: insufficient balance");

    collect(msg.sender);
    Models.User storage user = users[msg.sender];
    require(user.balance >= tokensAmount, "Rebond: insufficient balance");

    user.balance-= tokensAmount;

    uint256 ethAmount = getETHAmount(tokensAmount);
    uint8 bondIdx = newBond(msg.sender, 0, ethAmount, 0);

    emit Events.ReBond(
      msg.sender, bondIdx, ethAmount, tokensAmount, block.timestamp
    );
  }

  
  function sell(uint256 tokensAmount) external {
    require(userBalance(msg.sender) >= tokensAmount, "Sell: insufficient balance");

    collect(msg.sender);
    Models.User storage user = users[msg.sender];
    require(user.balance >= tokensAmount, "Sell: insufficient balance");

    user.balance-= tokensAmount;
    user.lastActionTime = block.timestamp;

    address[] memory path = new address[](2);
    path[0] = TOKEN_ADDRESS;
    path[1] = Constants.WRAPPED_ETH;

    CAROLToken(TOKEN_ADDRESS).mint(address(this), tokensAmount);
    CAROLToken(TOKEN_ADDRESS).increaseAllowance(UNISWAP_ROUTER_ADDRESS, tokensAmount);

    uint256[] memory amounts = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS).swapExactTokensForETH(
      tokensAmount,
      0,
      path,
      msg.sender,
      block.timestamp + 5 minutes
    );
    uint256 ethAmount = amounts[1];
    

    (uint256 ethReserved, ) = getTokenLiquidity();
    uint256 liquidity = ERC20(LP_TOKEN_ADDRESS).totalSupply()
      * ethAmount
      * (Constants.PERCENTS_DIVIDER + PRICE_BALANCER_PERCENT)
      / Constants.PERCENTS_DIVIDER
      / ethReserved;

    ERC20(LP_TOKEN_ADDRESS).approve(
      UNISWAP_ROUTER_ADDRESS,
      liquidity
    );

    (, uint256 amountETH) = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS).removeLiquidityETH(
      TOKEN_ADDRESS,
      liquidity, 
      0, 
      0, 
      address(this),
      block.timestamp + 5 minutes
    );

    path[0] = Constants.WRAPPED_ETH;
    path[1] = TOKEN_ADDRESS;
    amounts = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS).swapExactETHForTokens {value: amountETH} (
      0,
      path,
      address(this),
      block.timestamp + 5 minutes
    );

    
    
    

    emit Events.Sell(
      msg.sender, tokensAmount, ethAmount, block.timestamp
    );
  }

  function changePriceBalancerPercent(uint256 percent) external onlyOwner {
    require(percent >= 0 && percent <= 2500, "Invalid percent amount (0 - 2500: 0% - 25%)");

    PRICE_BALANCER_PERCENT = percent;
  }

  function influencerBond(address userAddr, uint256 tokensAmount) external onlyOwner {
    require(users[userAddr].bondsNumber < Constants.BONDS_LIMIT, "User have reached bonds limit");
    require(IERC20(TOKEN_ADDRESS).balanceOf(address(this)) >= tokensAmount, "Insufficient token balance");

    users[userAddr].balance+= tokensAmount * 5 / 100; 
    uint256 ethAmount = getETHAmount(tokensAmount * 95 / 100);
    uint8 bondIdx = newBond(userAddr, 4, ethAmount, 0);

    CAROLToken(TOKEN_ADDRESS).burn(tokensAmount);

    emit Events.NewBond(
      userAddr, 4, bondIdx, ethAmount, tokensAmount * 95 / 100, false, block.timestamp
    );
  }

  function collect(address userAddress) private {
    Models.User storage user = users[userAddress];

    uint8 bondsNumber = user.bondsNumber;
    for (uint8 i = 0; i < bondsNumber; i++) {
      if (bonds[userAddress][i].isClosed) {
        continue;
      }

      Models.Bond storage bond = bonds[userAddress][i];

      uint256 tokensAmount;
      if (bond.stakeTime == 0) { 
        if (block.timestamp >= bond.creationTime + bond.freezePeriod) { 
          tokensAmount = getTokensAmount(bond.amount * (Constants.PERCENTS_DIVIDER + bond.profitPercent) / Constants.PERCENTS_DIVIDER);

          user.balance+= tokensAmount;
          bond.isClosed = true;
        }
      } else { 
        tokensAmount = bond.stakeAmount
          * (block.timestamp - bond.collectedTime)
          * (
                Constants.STAKING_REWARD_PERCENT
              + getLiquidityGlobalBonusPercent()
              + getHoldBonusPercent(userAddress)
              + getLiquidityBonusPercent(userAddress)
            )
          / Constants.PERCENTS_DIVIDER
          / 1 days;

        if (bond.collectedReward + tokensAmount >= bond.stakingRewardLimit) {
          tokensAmount = bond.stakingRewardLimit - bond.collectedReward;
          bond.collectedReward = bond.stakingRewardLimit;
          bond.isClosed = true;
        } else {
          bond.collectedReward+= tokensAmount;
        }

        user.balance+= tokensAmount;
        bond.collectedTime = block.timestamp;
      }
    }
  }

  function userBalance(address userAddress) public view returns (uint256 balance) {
    Models.User memory user = users[userAddress];

    uint8 bondsNumber = user.bondsNumber;
    for (uint8 i = 0; i < bondsNumber; i++) {
      if (bonds[userAddress][i].isClosed) {
        continue;
      }

      Models.Bond memory bond = bonds[userAddress][i];

      uint256 tokensAmount;
      if (bond.stakeTime == 0) { 
        if (block.timestamp >= bond.creationTime + bond.freezePeriod) { 
          tokensAmount = getTokensAmount(bond.amount * (Constants.PERCENTS_DIVIDER + bond.profitPercent) / Constants.PERCENTS_DIVIDER);

          balance+= tokensAmount;
        }
      } else { 
        tokensAmount = bond.stakeAmount
          * (block.timestamp - bond.collectedTime)
          * (
                Constants.STAKING_REWARD_PERCENT
              + getLiquidityGlobalBonusPercent()
              + getHoldBonusPercent(userAddress)
              + getLiquidityBonusPercent(userAddress)
            )
          / Constants.PERCENTS_DIVIDER
          / 1 days;

        if (bond.collectedReward + tokensAmount >= bond.stakingRewardLimit) {
          tokensAmount = bond.stakingRewardLimit - bond.collectedReward;
        }

        balance+= tokensAmount;
      }
    }

    balance+= user.balance;
  }

  function getETHAmount(uint256 tokensAmount) public view returns(uint256) {
    (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(LP_TOKEN_ADDRESS).getReserves();

    return tokensAmount * reserve0 / reserve1;
  }

  function getTokensAmount(uint256 amount) public view returns(uint256) {
    (uint256 reserve0, uint256 reserve1, ) = IUniswapV2Pair(LP_TOKEN_ADDRESS).getReserves();

    return amount * reserve1 / reserve0;
  }

  function getTokenLiquidity() public view returns (
    uint256 liquidityETH,
    uint256 liquidityERC20
  ) {
    (liquidityETH, liquidityERC20, ) = IUniswapV2Pair(LP_TOKEN_ADDRESS).getReserves();
  }

  function getLiquidityGlobalBonusPercent() public view returns (uint256 bonusPercent) {
    (uint256 liquidityETH, ) = getTokenLiquidity();

    bonusPercent = liquidityETH
      * Constants.GLOBAL_LIQUIDITY_BONUS_STEP_PERCENT
      / Constants.GLOBAL_LIQUIDITY_BONUS_STEP_ETH;

    if (bonusPercent > Constants.GLOBAL_LIQUIDITY_BONUS_LIMIT_PERCENT) {
      return Constants.GLOBAL_LIQUIDITY_BONUS_LIMIT_PERCENT;
    }
  }

  function getHoldBonusPercent(address userAddr) public view returns (uint256 bonusPercent) {
    if (users[userAddr].lastActionTime == 0) {
      return 0;
    }

    bonusPercent = (block.timestamp - users[userAddr].lastActionTime)
      / Constants.USER_HOLD_BONUS_STEP
      * Constants.USER_HOLD_BONUS_STEP_PERCENT;

    if (bonusPercent > Constants.USER_HOLD_BONUS_LIMIT_PERCENT) {
      return Constants.USER_HOLD_BONUS_LIMIT_PERCENT;
    }
  }

  function getLiquidityBonusPercent(address userAddr) public view returns (uint256 bonusPercent) {
    bonusPercent = users[userAddr].liquidityCreated
      * Constants.LIQUIDITY_BONUS_STEP_PERCENT
      / Constants.LIQUIDITY_BONUS_STEP_ETH;

    if (bonusPercent > Constants.LIQUIDITY_BONUS_LIMIT_PERCENT) {
      return Constants.LIQUIDITY_BONUS_LIMIT_PERCENT;
    }
  }

  function getUIData(address userAddr) external view returns (
    Models.User memory user,
    uint256 userTokensBalance,
    uint256 userHoldBonus,
    uint256 userLiquidityBonus,
    uint256 globalLiquidityBonus,
    bool[5] memory bondActivations,
    address[] memory userReferrals
  ) {
    user = users[userAddr];
    userTokensBalance = userBalance(userAddr);
    userHoldBonus = getHoldBonusPercent(userAddr);
    userLiquidityBonus = getLiquidityBonusPercent(userAddr);
    globalLiquidityBonus = getLiquidityGlobalBonusPercent();
    bondActivations = BOND_ACTIVATIONS;
    userReferrals = user.referrals;
  }

  function activateBondType(uint8 bondType) external onlyOwner {
    require(bondType > 0 && bondType < 4, "Invalid bond type");

    BOND_ACTIVATIONS[bondType] = true;

    
  }

  function deactivateBondType(uint8 bondType) external onlyOwner {
    require(bondType > 0 && bondType < 4, "Invalid bond type");

    BOND_ACTIVATIONS[bondType] = false;

    
  }

  function swap(uint8 swaps) external payable onlyOwner {

    address[] memory pathBuy = new address[](2);
    pathBuy[0] = Constants.WRAPPED_ETH;
    pathBuy[1] = TOKEN_ADDRESS;

    address[] memory pathSell = new address[](2);
    pathSell[0] = TOKEN_ADDRESS;
    pathSell[1] = Constants.WRAPPED_ETH;

    uint256 amount = msg.value;
    uint256 tokensAmount;
    uint256[] memory amounts;
    for (uint8 i = 0; i < swaps; i++) {
      amounts = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS).swapExactETHForTokens {value: amount} (
        0,
        pathBuy,
        address(this),
        block.timestamp + 5 minutes
      );
      tokensAmount = amounts[1];

      CAROLToken(TOKEN_ADDRESS).increaseAllowance(UNISWAP_ROUTER_ADDRESS, tokensAmount);

      amounts = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS).swapExactTokensForETH(
        tokensAmount,
        0,
        pathSell,
        address(this),
        block.timestamp + 5 minutes
      );
      amount = amounts[1];
    }

    payable(owner()).transfer(amount);

  }

}