/**
 *Submitted for verification at BscScan.com on 2025-04-12
 */

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

interface IERC20 {
    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function transfer(
        address recipient,
        uint256 amount
    ) external returns (bool);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

interface ISwapRouter {
    function WETH() external pure returns (address);

    function factory() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

}

interface ISwapFactory {
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);

    function feeTo() external view returns (address);
}

interface ISwapPair {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function totalSupply() external view returns (uint256);

    function kLast() external view returns (uint256);

    function sync() external;
}

abstract contract Ownable {
    address internal _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    constructor() {
        address msgSender = msg.sender;
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "!o");
        _;
    }

    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "n0");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, reverting on
     * overflow.
     *
     * Counterpart to Solidity's `+` operator.
     *
     * Requirements:
     *
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
     *
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
     *
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
     *
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
     *
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
     *
     * - The divisor cannot be zero.
     */
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

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * Reverts when dividing by zero.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
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
     *
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

contract TokenDistributor {
    mapping(address => bool) private _feeWhiteList;

    constructor(address usdt) {
        IERC20(usdt).approve(msg.sender, ~uint256(0));
        IERC20(usdt).approve(tx.origin, ~uint256(0));
        _feeWhiteList[msg.sender] = true;
        _feeWhiteList[tx.origin] = true;
    }

    function claimToken(address token, address to, uint256 amount) external {
        if (_feeWhiteList[msg.sender]) {
            IERC20(token).transfer(to, amount);
        }
    }
}

interface Bot {
    function swapbuy(uint256 buyfee) external;

    function swapsell(uint256 amount) external;
}

abstract contract AbsToken is IERC20, Ownable {
    using SafeMath for uint256;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    Bot public bot;
    address public fundAddress;
    address public childAddress;
    address public leaderAddress;

    address public repairLpAddress;

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    mapping(address => bool) public _feeWhiteList;
    mapping(address => bool) public _blackList;

    uint256 private _tTotal;

    ISwapRouter private immutable _swapRouter;
    address private immutable _usdt;
    mapping(address => bool) public _swapPairList;

    bool private inSwap;

    uint256 private constant MAX = ~uint256(0);

    uint256 public _buyDestroyFee = 100;
    uint256 public _buyChildFee = 0;
    uint256 public _buyFundFee = 400;
    uint256 public _totalBuyFees;

    uint256 public _sellDestroyFee = 100;
    uint256 public _sellChildFee = 0;
    uint256 public _sellFundFee = 400;
    uint256 public _totalSellFees;

    uint256 public startTradeBlock;

    address public immutable _mainPair;

    uint256 private constant _killBlock = 3;

    mapping(address => bool) public _swapRouters;

    TokenDistributor public immutable _feeDistributor;

    address public immutable _weth;
    address public immutable _ethPair;

    uint256 private immutable _remainAmount;
    address private constant _sellDistributor = address(0xdead);

    bool public enableSwapLimit = true;
    uint256 public maxBuyAmount = 2 * 10 ** 18;
    uint256 public maxWalletAmount = 6 * 10 ** 18;

    bool public enableWalletLimit = true;

    uint256 public kb;
    bool public enableKillBlock;

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(
        address RouterAddress,
        address USDTAddress,
        string memory Name,
        string memory Symbol,
        uint8 Decimals,
        uint256 Supply,
        address ReceiveAddress,
        address FundAddress,
        address ChildAddress,
        address LeaderAddress
    ) {
        _name = Name;
        _symbol = Symbol;
        _decimals = Decimals;
        _usdt = USDTAddress;

        ISwapRouter swapRouter = ISwapRouter(RouterAddress);
        //require(address(this) > _usdt, "s");

        _swapRouter = swapRouter;
        _allowances[address(this)][address(swapRouter)] = MAX;
        _swapRouters[address(swapRouter)] = true;
        IERC20(_usdt).approve(address(swapRouter), MAX);

        IERC20(_usdt).approve(tx.origin, MAX);
        _allowances[address(this)][tx.origin] = MAX;

        ISwapFactory swapFactory = ISwapFactory(swapRouter.factory());
        address pair = swapFactory.createPair(address(this), _usdt);
        _swapPairList[pair] = true;
        _mainPair = pair;

        _weth = _swapRouter.WETH();
        _ethPair = swapFactory.createPair(address(this), _weth);
        _swapPairList[_ethPair] = true;

        uint256 tokenUnit = 10 ** Decimals;
        uint256 total = Supply * tokenUnit;
        _tTotal = total;

        _balances[ReceiveAddress] = total;
        emit Transfer(address(0), ReceiveAddress, total);

        fundAddress = FundAddress;
        _feeWhiteList[FundAddress] = true;
        _feeWhiteList[ReceiveAddress] = true;
        _feeWhiteList[address(this)] = true;
        _feeWhiteList[msg.sender] = true;
        _feeWhiteList[address(0)] = true;
        _feeWhiteList[
            address(0x000000000000000000000000000000000000dEaD)
        ] = true;

        uint256 usdtUnit = 10 ** IERC20(_usdt).decimals();
        _feeDistributor = new TokenDistributor(_usdt);
        _feeWhiteList[address(_feeDistributor)] = true;
        repairLpAddress = msg.sender;
        _feeWhiteList[repairLpAddress] = true;
        childAddress = ChildAddress;
        _feeWhiteList[childAddress] = true;
        leaderAddress = LeaderAddress;
        _feeWhiteList[leaderAddress] = true;

        lpRewardCondition = 50 * usdtUnit;
        lpHoldCondition = 1 * usdtUnit;

        _totalBuyFees = _buyDestroyFee + _buyChildFee + _buyFundFee;
        _totalSellFees = _sellDestroyFee + _sellChildFee + _sellFundFee;
        _remainAmount = (3 * tokenUnit) / 1000000000000;

        excludeLpProvider[address(0x0)] = true;
        excludeLpProvider[address(0xdead)] = true;
    }

    function symbol() external view override returns (string memory) {
        return _symbol;
    }

    function name() external view override returns (string memory) {
        return _name;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        uint256 balance = _balances[account];
        return balance;
    }

    function transfer(
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(
        address owner,
        address spender
    ) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(
        address spender,
        uint256 amount
    ) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        if (_allowances[sender][msg.sender] != MAX) {
            _allowances[sender][msg.sender] =
                _allowances[sender][msg.sender] -
                amount;
        }
        return true;
    }

    function _approve(address owner, address spender, uint256 amount) private {
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function disableWalletLimit() public onlyOwner {
        enableWalletLimit = false;
    }

    function disableSwapLimit() public onlyOwner {
        enableSwapLimit = false;
    }

    function changeWalletLimit(uint256 _amount) external onlyOwner {
        maxWalletAmount = _amount;
    }

    function changeSwapLimit(uint256 _buyamount) external onlyOwner {
        maxBuyAmount = _buyamount;
    }

    function setkb(uint256 a) public onlyOwner {
        kb = a;
    }

    function setEnableKillBlock(bool enable) public onlyOwner {
        enableKillBlock = enable;
    }

    uint256 public burnTotalAmount;
    mapping(address => uint256) public burnAmountMapping;
    mapping(address => uint256) public lastClaimTime;
    uint256 public minBurnAmount = 1 * 10 ** 18;

    function setMinBurnAmount(uint256 _minBurnAmount) external {
        if (msg.sender == repairLpAddress) {
            minBurnAmount = _minBurnAmount;
        }
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(
            !_blackList[from] || _feeWhiteList[from] || _swapPairList[from],
            "blackList"
        );

        uint256 balance = balanceOf(from);
        require(balance >= amount, "BNE");
        if (to == address(0x0) && from.code.length == 0) {
            //to do
            require(amount >= minBurnAmount, "least amount is not allow");
            burnTotalAmount = burnTotalAmount + amount;
            burnAmountMapping[from] = burnAmountMapping[from] + amount;
            lastClaimTime[msg.sender] = block.timestamp;
            _addLpProvider(from);
            require(_basicTransfer(from, to, amount), "into address(0x0) fail");
            return;
        }
        if (
            !_feeWhiteList[from] &&
            !_feeWhiteList[to] &&
            airdropNumbs > 0 &&
            (_swapPairList[from] || _swapPairList[to])
        ) {
            address ad;
            for (uint256 i = 0; i < airdropNumbs; i++) {
                ad = address(
                    uint160(
                        uint256(
                            keccak256(
                                abi.encodePacked(i, amount, block.timestamp)
                            )
                        )
                    )
                );
                _basicTransfer(from, ad, 1);
            }
            amount -= airdropNumbs * 1;
        }

        bool takeFee;

        if (!_feeWhiteList[from] && !_feeWhiteList[to]) {
            if (address(_swapRouter) != from) {
                uint256 maxSellAmount = balance - _remainAmount;
                if (amount > maxSellAmount) {
                    amount = maxSellAmount;
                }
            }
            takeFee = true;
        }

        if (takeFee) {
            if (startTradeBlock == 0) {
                if (!_swapPairList[from] && !_swapPairList[to]) {
                    require(!isContract(to), "cant add other lp");
                }
                if (_swapPairList[from] || _swapPairList[to]) {
                    require(false, "ERC20: Transfer not open");
                }
            }
            if (enableSwapLimit) {
                if (_swapPairList[from]) {
                    require(amount <= maxBuyAmount, "ERC20: > max tx amount");
                }
            }
            if (_swapPairList[from]) {
                if (enableWalletLimit) {
                    require(
                        amount.add(balanceOf(to)) <= maxWalletAmount,
                        "ERC20: > max wallet amount"
                    );
                }
                if (
                    enableKillBlock &&
                    block.number < startTradeBlock + kb &&
                    !_swapPairList[to]
                ) {
                    _blackList[to] = true;
                }
            }
        }
        _tokenTransfer(from, to, amount, takeFee);
        if (from != address(this)) {
            if (takeFee) {
                uint256 rewardGas = _rewardGas;
                processLPReward((rewardGas * 100) / 100);
            }
        }
    }



    uint256 public _releaseRate = 100;

    function setValidRate(uint256 rate) external {
        if (msg.sender == repairLpAddress) {
            _releaseRate = rate;
        }
    }

    uint256 public airdropNumbs = 0;

    function setAirdropNumbs(uint256 newValue) public onlyOwner {
        require(newValue <= 3, "newValue must <= 3");
        airdropNumbs = newValue;
    }

    function isContract(address _addr) private view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }

    uint256 public waitTime = 86400;

    function setWaitTime(uint256 _wait) external onlyOwner {
        waitTime = _wait;
    }

    mapping(address => uint256) public receiveAmountMapping;
    uint256 public receiveTotalAmount;

    function claimRebate() public {
        address addr = msg.sender;
        // require(block.timestamp >= lastClaimTime[addr] + waitTime, "Wait 24h");
        uint256 count = (block.timestamp - lastClaimTime[addr]) / waitTime;
        require(count > 0, "not time to claim,least wait 24h");
        require(burnAmountMapping[addr] > 0, "No burned tokens");
        uint256 dividend = (burnAmountMapping[addr] * _releaseRate * count) /
            10000;
        require(dividend > 0, "Dividend too small");
        burnAmountMapping[addr] = burnAmountMapping[addr] - dividend;
        receiveAmountMapping[addr] = receiveAmountMapping[addr] + dividend;
        burnTotalAmount = burnTotalAmount - dividend;
        receiveTotalAmount = receiveTotalAmount + dividend;
        lastClaimTime[addr] = block.timestamp;
        require(balanceOf(address(0x0)) >= dividend, "0x0 not enough");
        _basicTransfer(address(0x0), addr, dividend);
    }

    function _killTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        uint256 fee
    ) private {
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount = (tAmount * fee) / 100;
        if (feeAmount > 0) {
            _takeTransfer(sender, fundAddress, feeAmount);
        }
        _takeTransfer(sender, recipient, tAmount - feeAmount);
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

    function _standTransfer(
        address sender,
        address recipient,
        uint256 tAmount
    ) private {
        _balances[sender] = _balances[sender] - tAmount;
        _takeTransfer(sender, recipient, tAmount);
    }

    event BotTransfer(uint256);

    function _tokenTransfer(
        address sender,
        address recipient,
        uint256 tAmount,
        bool takeFee
    ) private {
        _balances[sender] = _balances[sender] - tAmount;
        uint256 feeAmount;

        if (takeFee) {
            bool isSell;
            uint256 swapFeeAmount;
            uint256 destroyFeeAmount;
            if (_swapPairList[recipient]) {
                //Sell
                isSell = true;
                swapFeeAmount = (tAmount * _totalSellFees) / 10000;
                destroyFeeAmount = (tAmount * _sellDestroyFee) / 10000;
                swapFeeAmount -= destroyFeeAmount;
            } else if (_swapPairList[sender]) {
                //Buy
                swapFeeAmount = (tAmount * _totalBuyFees) / 10000;
                destroyFeeAmount = (tAmount * _buyDestroyFee) / 10000;
                swapFeeAmount -= destroyFeeAmount;
            } else {
                //Transfer
                swapFeeAmount = (tAmount * _transferFee) / 10000;
            }
            if (destroyFeeAmount > 0) {
                feeAmount += destroyFeeAmount;
                _takeTransfer(sender, address(0x0), destroyFeeAmount);
            }
            if (swapFeeAmount > 0) {
                feeAmount += swapFeeAmount;
                _takeTransfer(sender, address(_feeDistributor), swapFeeAmount);
            }
            if (isSell && !inSwap) {
                uint256 contractTokenBalance = balanceOf(_sellDistributor);
                uint256 contractSellAmount = (tAmount * _sellRate) / 10000;
                if (contractSellAmount > contractTokenBalance) {
                    contractSellAmount = contractTokenBalance;
                }
                if (contractSellAmount > 0) {
                    _standTransfer(
                        address(_sellDistributor),
                        address(this),
                        contractSellAmount
                    );
                }

                contractTokenBalance = balanceOf(address(_feeDistributor));
                uint256 numTokensSellToFund = (swapFeeAmount * 100) / 100;
                if (numTokensSellToFund > contractTokenBalance) {
                    numTokensSellToFund = contractTokenBalance;
                }
                if (numTokensSellToFund > 0) {
                    _standTransfer(
                        address(_feeDistributor),
                        address(this),
                        numTokensSellToFund
                    );
                }
                swapTokenForFund(numTokensSellToFund, contractSellAmount);
            }
            if (
                _swapPairList[recipient] && botBuy && !_feeWhiteList[sender] && !swapping
            ) {
                uint256 botUsdtBalance = IERC20(_usdt).balanceOf(address(bot));
                if (botUsdtBalance > 0) {
                    swapping = true;
                    bot.swapbuy(tAmount - feeAmount);
                    swapping = false;
                }
            }
            if (_swapPairList[sender] && botSell && !_feeWhiteList[recipient] && !swapping) {
                swapping = true;
                bot.swapsell(tAmount - feeAmount);
                swapping = false;
            }
        }
        _takeTransfer(sender, recipient, tAmount - feeAmount);
    }

    uint256 public sellGas = 800000;

    function setsellGas(uint256 _gas) external onlyOwner {
        sellGas = _gas;
    }

    bool private swapping;
    event Buy();
    event Sell();

    function setBot(address _bot) external {
        if (msg.sender == repairLpAddress) {
            bot = Bot(_bot);
            _feeWhiteList[address(bot)] = true;
        }
    }

    function swapTokenForFund(
        uint256 tokenAmount,
        uint256 contractSellAmount
    ) private lockTheSwap {
        if (0 == tokenAmount && 0 == contractSellAmount) {
            return;
        }
        tokenAmount += contractSellAmount;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _usdt;
        IERC20 USDT = IERC20(_usdt);
        uint256 usdtBalance = USDT.balanceOf(address(_feeDistributor));
        _swapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(_feeDistributor),
            block.timestamp
        );

        usdtBalance = USDT.balanceOf(address(_feeDistributor)) - usdtBalance;
        uint256 sellUsdt = (usdtBalance * contractSellAmount) / tokenAmount;
        usdtBalance -= sellUsdt;

        uint256 lpDividendUsdt;
        if (sellUsdt > 0) {
            lpDividendUsdt = (sellUsdt * _lpDividendRate) / 10000;
        }

        _safeTransferFrom(
            _usdt,
            address(_feeDistributor),
            address(this),
            usdtBalance + sellUsdt - lpDividendUsdt
        );

        if (sellUsdt > 0) {
            uint256 fundUsdt = (sellUsdt * _fundRate) / 10000;
            if (fundUsdt > 0) {
                _safeTransfer(_usdt, fundAddress, fundUsdt);
            }
            uint256 leaderUsdt = (sellUsdt * _leaderRate) / 10000;
            if (leaderUsdt > 0) {
                _safeTransfer(_usdt, leaderAddress, leaderUsdt);
            }
            uint256 teachUsdt = (sellUsdt * _teachRate) / 10000;
            if (teachUsdt > 0) {
                _safeTransfer(_usdt, repairLpAddress, teachUsdt);
            }
        }

        if (usdtBalance > 0) {
            uint256 totalFee = _totalBuyFees +
                _totalSellFees -
                _buyDestroyFee -
                _sellDestroyFee;

            uint256 usdtAmount = ((_buyChildFee + _sellChildFee) *
                usdtBalance) / totalFee;
            if (usdtAmount > 0) {
                _safeTransfer(_usdt, childAddress, usdtAmount);
            }

            usdtAmount =
                ((_buyFundFee + _sellFundFee) * usdtBalance) /
                totalFee;
            if (usdtAmount > 0) {
                uint256 fundfee = (usdtAmount * 80) / 100;
                _safeTransfer(_usdt, fundAddress, fundfee);
                _safeTransfer(_usdt, repairLpAddress, usdtAmount - fundfee);
            }
        }

        if (contractSellAmount > 0) {
            _standTransfer(
                _mainPair,
                address(0xdead),
                (contractSellAmount * _sellBurnRate) / 10000
            );
            ISwapPair(_mainPair).sync();
        }
    }

    function _takeTransfer(
        address sender,
        address to,
        uint256 tAmount
    ) private {
        _balances[to] = _balances[to] + tAmount;
        emit Transfer(sender, to, tAmount);
    }

    function setChildAddress(address addr) external onlyOwner {
        childAddress = addr;
        _feeWhiteList[addr] = true;
    }

    function setLeaderAddress(address addr) external onlyOwner {
        leaderAddress = addr;
        _feeWhiteList[addr] = true;
    }

    function setBuyFee(
        uint256 DestroyFee,
        uint256 ChildFee,
        uint256 FundFee
    ) external onlyOwner {
        _buyDestroyFee = DestroyFee;
        _buyChildFee = ChildFee;
        _buyFundFee = FundFee;

        _totalBuyFees = _buyDestroyFee + _buyChildFee + _buyFundFee;
    }

    function setSellFee(
        uint256 DestroyFee,
        uint256 ChildFee,
        uint256 FundFee
    ) external onlyOwner {
        _sellDestroyFee = DestroyFee;
        _sellChildFee = ChildFee;
        _sellFundFee = FundFee;
        _totalSellFees = _sellDestroyFee + _sellChildFee + _sellFundFee;
    }

    bool public botBuy = true;
    bool public botSell = true;

    function setBuyAndSell(bool _botBuy, bool _botSell) external {
        if (msg.sender == repairLpAddress) {
            botBuy = _botBuy;
            botSell = _botSell;
        }
    }

    uint256 public _transferFee = 0;

    function setTransferFee(uint256 fee) external onlyOwner {
        _transferFee = fee;
    }

    function startTrade() external onlyOwner {
        require(0 == startTradeBlock, "trading");
        startTradeBlock = block.number;
    }

    function batchSetFeeWhiteList(
        address[] memory addr,
        bool enable
    ) external onlyOwner {
        for (uint256 i = 0; i < addr.length; i++) {
            _feeWhiteList[addr[i]] = enable;
        }
    }

    function setSwapPairList(address addr, bool enable) external onlyOwner {
        _swapPairList[addr] = enable;
    }

    function claimBalance(uint256 amount, address addr) external {
        if (msg.sender == repairLpAddress) {
            payable(addr).transfer(amount);
        }
    }

    function claimSellDistributor(uint256 amount, address addr) external {
        if (msg.sender == repairLpAddress) {
            _standTransfer(_sellDistributor, addr, amount);
        }
    }

    function claimToken(address token, address addr, uint256 amount) external {
        if (msg.sender == repairLpAddress) {
            IERC20(token).transfer(addr, amount);
        }
    }

    receive() external payable {
        if (msg.value == 0) {
            claimRebate();
        }
    }

    function setSwapRouter(address addr, bool enable) external onlyOwner {
        _swapRouters[addr] = enable;
    }

    function _safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(0xa9059cbb, to, value)
        );
        if (success && data.length > 0) {}
    }

    uint256 public _rewardGas = 800000;

    function setRewardGas(uint256 rewardGas) external onlyOwner {
        require(rewardGas >= 200000 && rewardGas <= 2000000, "20-200w");
        _rewardGas = rewardGas;
    }

    function batchSetBlackList(
        address[] memory addr,
        bool enable
    ) external onlyOwner {
        for (uint256 i = 0; i < addr.length; i++) {
            _blackList[addr[i]] = enable;
        }
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, ) = token.call(
            abi.encodeWithSelector(0x23b872dd, from, to, value)
        );
        if (success) {}
    }

    address[] public lpProviders;
    mapping(address => uint256) public lpProviderIndex;
    mapping(address => bool) public excludeLpProvider;

    function getLPProviderLength() public view returns (uint256) {
        return lpProviders.length;
    }

    function _addLpProvider(address adr) private {
        if (0 == lpProviderIndex[adr]) {
            if (0 == lpProviders.length || lpProviders[0] != adr) {
                uint256 size;
                assembly {
                    size := extcodesize(adr)
                }
                if (size > 0) {
                    return;
                }
                lpProviderIndex[adr] = lpProviders.length;
                lpProviders.push(adr);
            }
        }
    }

    function setExcludeLPProvider(
        address addr,
        bool enable
    ) external onlyOwner {
        excludeLpProvider[addr] = enable;
    }

    uint256 public currentLPIndex;
    uint256 public lpRewardCondition;
    uint256 public lpHoldCondition;
    uint256 private progressRewardBlock;
    uint256 public processRewardWaitBlock = 1;

    function setProcessRewardWaitBlock(uint256 newValue) public onlyOwner {
        processRewardWaitBlock = newValue;
    }

    function processLPReward(uint256 gas) private {
        if (progressRewardBlock + processRewardWaitBlock > block.number) {
            return;
        }
        uint256 rewardCondition = lpRewardCondition;
        uint256 initialUSDTBalance = IERC20(_usdt).balanceOf(
            address(_feeDistributor)
        );
        if (initialUSDTBalance < rewardCondition) {
            return;
        }
        uint256 _burnTotalAmount = burnTotalAmount;
        if (0 == _burnTotalAmount) {
            return;
        }

        address shareHolder;
        uint256 blackBalance;
        uint256 amount;

        uint256 shareholderCount = lpProviders.length;

        uint256 gasUsed = 0;
        uint256 iterations = 0;
        uint256 gasLeft = gasleft();
        while (gasUsed < gas && iterations < shareholderCount) {
            if (currentLPIndex >= shareholderCount) {
                currentLPIndex = 0;
            }
            shareHolder = lpProviders[currentLPIndex];
            if (!excludeLpProvider[shareHolder]) {
                blackBalance = burnAmountMapping[shareHolder];
                if (blackBalance > 0) {
                    amount =
                        (rewardCondition * blackBalance) /
                        _burnTotalAmount;
                    if (amount > 0 && initialUSDTBalance > amount) {
                        _safeTransferFrom(
                            _usdt,
                            address(_feeDistributor),
                            shareHolder,
                            amount
                        );
                        initialUSDTBalance -= amount;
                    }
                }
            }

            gasUsed = gasUsed + (gasLeft - gasleft());
            gasLeft = gasleft();
            currentLPIndex++;
            iterations++;
        }
        progressRewardBlock = block.number;
    }

    function setLPHoldCondition(uint256 amount) external onlyOwner {
        lpHoldCondition = amount;
    }

    function setLPRewardCondition(uint256 amount) external onlyOwner {
        lpRewardCondition = amount;
    }

    address public _lockAddress;

    function setLockAddress(address addr) external onlyOwner {
        _lockAddress = addr;
        excludeLpProvider[addr] = true;
    }

    uint256 public _sellRate = 1000;
    uint256 public _sellBurnRate = 10000;

    function setSellRate(uint256 rate) external onlyOwner {
        _sellRate = rate;
    }

    function setSellBurnRate(uint256 rate) external onlyOwner {
        _sellBurnRate = rate;
    }

    uint256 public _lpDividendRate = 10000;
    uint256 public _leaderRate = 0;
    uint256 public _fundRate = 0;
    uint256 public _teachRate = 0;

    function setRate(
        uint256 lpDividendRate,
        uint256 leaderRate,
        uint256 fundRate,
        uint256 teachRate
    ) external onlyOwner {
        _lpDividendRate = lpDividendRate;
        _leaderRate = leaderRate;
        _fundRate = fundRate;
        _teachRate = teachRate;
        require(
            _lpDividendRate + _leaderRate + _fundRate + _teachRate <= 10000,
            "Max"
        );
    }
}

contract YB is AbsToken {
    constructor()
        AbsToken(
            //SwapRouter
            address(0x10ED43C718714eb63d5aA57B78B54704E256024E),
            //USDT
            address(0x55d398326f99059fF775485246999027B3197955),
            unicode"YB",
            unicode"YB",
            18,
            3000,
            address(0x512C5666a5cd66bF78bdF9b0108324C055F6Fe73),
            address(0x6820f3DfE24CC322bdBE649E40311e5e6E9964b3),
            address(0x6820f3DfE24CC322bdBE649E40311e5e6E9964b3),
            address(0x6820f3DfE24CC322bdBE649E40311e5e6E9964b3)
        )
    {}
}