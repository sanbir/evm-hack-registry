// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

interface IEERC314 {
  event Transfer(address indexed from, address indexed to, uint256 value);
  event AddLiquidity(uint32 _blockToUnlockLiquidity, uint256 value);
  event RemoveLiquidity(uint256 value);
  event Swap(address indexed sender, uint amount0In, uint amount1In, uint amount0Out, uint amount1Out);
}

abstract contract ERC314 is IEERC314 {
  mapping(address account => uint256) private _balances;

  uint256 private _totalSupply;
  uint32 public blockToUnlockLiquidity;

  string private _name;
  string private _symbol;

  address public liquidityProvider;

  bool public tradingEnable;
  bool public liquidityAdded;

  modifier onlyOwner() {
    require(msg.sender == owner, 'Ownable: caller is not the owner');
    _;
  }

  modifier onlyLiquidityProvider() {
    require(msg.sender == liquidityProvider, 'You are not the liquidity provider');
    _;
  }

  address public feeReceiver = 0x93fBf6b2D322C6C3e7576814d6F0689e0A333e96;
  address public owner = 0xCf309355E26636c77a22568F797deddcbE94e759;

  constructor(string memory name_, string memory symbol_, uint256 totalSupply_) {
    _name = name_;
    _symbol = symbol_;
    _totalSupply = totalSupply_;
    
    tradingEnable = false;

    _balances[address(this)] = totalSupply_;
    emit Transfer(address(0), address(this), totalSupply_);

    liquidityAdded = false;
  }

  function name() public view virtual returns (string memory) {
    return _name;
  }

  function symbol() public view virtual returns (string memory) {
    return _symbol;
  }

  function decimals() public view virtual returns (uint8) {
    return 18;
  }

  function totalSupply() public view virtual returns (uint256) {
    return _totalSupply;
  }

  function balanceOf(address account) public view virtual returns (uint256) {
    return _balances[account];
  }

  function transfer(address to, uint256 value) public virtual returns (bool) {
    // sell or transfer
    if (to == address(this)) {
      sell(value);
    } else {
      _transfer(msg.sender, to, value);
    }
    return true;
  }

  function _transfer(address from, address to, uint256 value) internal virtual {
    require(_balances[from] >= value, 'ERC20: transfer amount exceeds balance');

    unchecked {
      _balances[from] = _balances[from] - value;
    }

    if (to == address(0)) {
      unchecked {
        _totalSupply -= value;
      }
    } else {
      unchecked {
        _balances[to] += value;
      }
    }

    emit Transfer(from, to, value);
  }

  function getReserves() public view returns (uint256, uint256) {
    return (address(this).balance, _balances[address(this)]);
  }

  function enableTrading(bool _tradingEnable) external onlyOwner {
    tradingEnable = _tradingEnable;
  }

  function setFeeReceiver(address _feeReceiver) external onlyOwner {
    feeReceiver = _feeReceiver;
  }

  function renounceOwnership() external onlyOwner {
    owner = address(0);
  }

  function renounceLiquidityProvider() external onlyLiquidityProvider {
    liquidityProvider = address(0);
  }

  function transferOwnership(address newOwner) public virtual onlyOwner {
    require(newOwner != address(0), "Ownable: new owner is the zero address");
    owner = newOwner;
  }

  function addLiquidity(uint32 _blockToUnlockLiquidity) public payable {
    require(liquidityAdded == false, 'Liquidity already added');

    liquidityAdded = true;

    require(msg.value > 0, 'No ETH sent');
    require(block.number < _blockToUnlockLiquidity, 'Block number too low');

    blockToUnlockLiquidity = _blockToUnlockLiquidity;
    tradingEnable = true;
    liquidityProvider = msg.sender;

    emit AddLiquidity(_blockToUnlockLiquidity, msg.value);
  }

  function removeLiquidity() public onlyLiquidityProvider {
    require(block.number > blockToUnlockLiquidity, 'Liquidity locked');

    tradingEnable = false;

    payable(msg.sender).transfer(address(this).balance);

    emit RemoveLiquidity(address(this).balance);
  }

  function extendLiquidityLock(uint32 _blockToUnlockLiquidity) public onlyLiquidityProvider {
    require(blockToUnlockLiquidity < _blockToUnlockLiquidity, "You can't shorten duration");

    blockToUnlockLiquidity = _blockToUnlockLiquidity;
  }

  function getAmountOut(uint256 value, bool _buy) public view returns (uint256) {
    (uint256 reserveETH, uint256 reserveToken) = getReserves();

    if (_buy) {
      return ((value * reserveToken) / (reserveETH + value)) / 2;
    } else {
      return (value * reserveETH) / (reserveToken + value);
    }
  }

  function buy() internal {
    require(tradingEnable, 'Trading not enable');

    uint256 swapValue = msg.value;

    uint256 token_amount = (swapValue * _balances[address(this)]) / (address(this).balance);

    require(token_amount > 0, 'Buy amount too low');

    uint256 user_amount = token_amount * 50 / 100;
    uint256 fee_amount = token_amount - user_amount;

    _transfer(address(this), msg.sender, user_amount);
    _transfer(address(this), feeReceiver, fee_amount);

    emit Swap(msg.sender, swapValue, 0, 0, user_amount);
  }

  function sell(uint256 sell_amount) internal {
    require(tradingEnable, 'Trading not enable');

    uint256 ethAmount = (sell_amount * address(this).balance) / (_balances[address(this)] + sell_amount);

    require(ethAmount > 0, 'Sell amount too low');
    require(address(this).balance >= ethAmount, 'Insufficient ETH in reserves');

    uint256 swap_amount = sell_amount * 50 / 100;
    uint256 burn_amount = sell_amount - swap_amount;

    _transfer(msg.sender, address(this), swap_amount);
    _transfer(msg.sender, address(0), burn_amount);

    payable(msg.sender).transfer(ethAmount);

    emit Swap(msg.sender, 0, sell_amount, ethAmount, 0);
  }

  receive() external payable {
    buy();
  }
}

contract AIZPT314 is ERC314 {
  constructor() ERC314('AIZPT', 'AIZPT', 10000000000 * 10 ** 18) {}
}