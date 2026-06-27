/**
 *Submitted for verification at BscScan.com on 2023-12-15
*/

/**
https://t.me/zongzi
*/
//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
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
    function renounceOwnership() public virtual onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
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


interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;
}

interface IUniswapV2Pair {
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);

    function balanceOf(address owner) external view returns (uint256);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint256);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function price0CumulativeLast() external view returns (uint256);

    function price1CumulativeLast() external view returns (uint256);

    function kLast() external view returns (uint256);

    function mint(address to) external returns (uint256 liquidity);

    function burn(
        address to
    ) external returns (uint256 amount0, uint256 amount1);

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;
}
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

interface ILP {
    function addReward(uint256 amount) external;
}


contract ERC20 is Context, IERC20, IERC20Metadata {
    using SafeMath for uint256;

    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(
        address account
    ) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(
        address owner,
        address spender
    ) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(
        address spender,
        uint256 amount
    ) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(
                amount,
                "ERC20: transfer amount exceeds allowance"
            )
        );
        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].add(addedValue)
        );
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) public virtual returns (bool) {
        _approve(
            _msgSender(),
            spender,
            _allowances[_msgSender()][spender].sub(
                subtractedValue,
                "ERC20: decreased allowance below zero"
            )
        );
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
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(sender, recipient, amount);

        _balances[sender] = _balances[sender].sub(
            amount,
            "ERC20: transfer amount exceeds balance"
        );
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply = _totalSupply.add(amount);
        _balances[account] = _balances[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _zongzi(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: zongzi from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        _balances[account] = _balances[account].sub(
            amount,
            "ERC20: zongzi amount exceeds balance"
        );
        _totalSupply = _totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and zongziing.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be to transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be zongzied.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {}
}
interface IUniswapV2Router01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

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

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountETH);

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountA, uint256 amountB);

    function removeLiquidityETHWithPermit(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountToken, uint256 amountETH);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    function getAmountsIn(
        uint256 amountOut,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

interface IUniswapV2Router02 is IUniswapV2Router01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface zongziAbi {
    function launch() external view returns (bool);
    function setLaunch(bool flag) external;
}

contract zongziAirdrop is Context{
    using SafeMath for uint256;
    uint256 private constant _value = 2 * 10**15;
    uint256 public totalDroped;
    uint256 public threshold;
    uint256 private constant _deployAmount = 30 * 10**8 * 10 ** 18;
    uint256 private constant _singleAmount = 50 * 10**8 * 10 ** 18;
    uint256 public _block;
    uint256 private _countBlock;
    zongziAbi public _zongzi;
    IUniswapV2Router02 public uniswapRouter;
    bool inits = false;
    constructor(){}
    function init(address zongziAddr,address routeAddr)  public{
        require(!inits,'initsd');
        inits = true;
        _zongzi = zongziAbi(zongziAddr);
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(routeAddr);
        uniswapRouter = _uniswapV2Router;
    }

    function _drop() internal {
        address _msgSender = msg.sender;
        if(msg.value == _value && !_zongzi.launch() && _msgSender != address(this)){
            require(_msgSender == tx.origin, "Only EOA");
            if(_countBlock <10){
                ++_countBlock;
                ++totalDroped;
                ++threshold;
                if (totalDroped == 1 || totalDroped % 500 == 0) {
                    _deployLiquidity();
                }
                IERC20 token = IERC20(address(_zongzi));
                require(token.balanceOf(address(this)) >= _singleAmount, "Droped out");
                token.transfer( _msgSender, _singleAmount);
            }else if(_block != block.number){
                _block = block.number;
                _countBlock=0;
            }
            if(totalDroped>= 1250000 ){
                _zongzi.setLaunch(true);
                uint256 amount = payable(address(this)).balance;
                payable(address(_zongzi)).transfer(amount);
            }
        }
    }
    function _deployLiquidity() internal {
        uint256 _amount = _deployAmount.mul(threshold);
        uint256 balance = _value.mul(threshold).mul(12).div(20);
        uint256 amount = payable(address(this)).balance;
        if(amount>=balance){
            addLiquidity(_amount, balance);
            threshold = 0;
        }
    }
    
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        IERC20 token = IERC20(address(_zongzi));
        token.approve(address(uniswapRouter), tokenAmount);
        // add the liquidity
        uniswapRouter.addLiquidityETH{value: ethAmount}(
            address(_zongzi),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0xdead),
            block.timestamp
        );
    }
    //to recieve ETH from uniswapV2Router when swaping
    receive() external payable {
        _drop();
    }
}


interface zongziRewardHold {
    function zongziFeeRewards(address account,uint256 amount) external payable;
}

contract ZONGZI is ERC20, Ownable {
    using SafeMath for uint256;
    IUniswapV2Router02 public uniswapRouter;
    address public uniswapPair;
    uint256 public divFee = 1;
    uint256 public lpFee = 3;
    uint256 public marketFee = 3;
    uint256 public burnFee = 3;
    uint256 public minAccountBalance = 8888 * 10 ** 18;
    zongziRewardHold public zongziHolder;
    mapping(address => bool) _excludedFees;
    uint256 public minBalanceSwapToken = 10 ** 10 * 10 ** 18;
    bool swapIng;
    zongziAirdrop public airdropAddr;
    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;
    constructor() ERC20("ZongZi", "ZongZi") {
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E //bsc network
            //0xD99D1c33F9fC3444f8101754aBC46c52416550D1 //testbscnetwork
        );
        uniswapPair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(
            address(this),
            _uniswapV2Router.WETH()
        );
        zongziAirdrop _airdrop = new zongziAirdrop();
        _airdrop.init(address(this),address(_uniswapV2Router));
        _excludedFees[_msgSender()] = true;
        _excludedFees[address(this)] = true;
        _excludedFees[address(_airdrop)] = true;
        airdropAddr = _airdrop;
        //setting zongziHold address
        //zongziHolder = zongziRewardHold(0xeCb1ff7537bE8108dfeaF4E590fD720a8e4B56dA);
        _setAutomatedMarketMakerPair(address(uniswapPair), true);
        uniswapRouter = _uniswapV2Router;
        _approve(_msgSender(), address(uniswapRouter), ~uint256(0));
        _approve(address(this), address(uniswapRouter), ~uint256(0));
        _approve(address(_airdrop), address(uniswapRouter), ~uint256(0));
        _mint(address(_airdrop), 10 ** 16 * 10 ** 18);
    }
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    
    function setzongziHolder(
        address _addr
    ) external onlyOwner {
        zongziHolder = zongziRewardHold(_addr);
        _excludedFees[_addr] = true;
    }
    function setminBalanceSwapToken(
        uint256 _minBalanceSwapToken
    ) external onlyOwner {
        minBalanceSwapToken = _minBalanceSwapToken;
    }
    function isExcludedFromFees(address account) external view returns (bool) {
        return _excludedFees[account];
    }
    function setAutoLPzongziSettings(
        uint256 _frequencyInSeconds,
        uint256 _percent,
        bool _Enabled
    ) external onlyOwner {
        lpzongziFrequency = _frequencyInSeconds;
        percentForLPzongzi = _percent;
        lpzongziEnabled = _Enabled;
    }
    function excludedFromFees(
        address account,
        bool excluded
    ) external onlyOwner {
        _excludedFees[account] = excluded;
    }
    function setAutomatedMarketMakerPair(address pair, bool value)
        public
        onlyOwner
    {
        require(
            pair != uniswapPair,
            "The pair cannot be removed from automatedMarketMakerPairs"
        );
        _setAutomatedMarketMakerPair(pair, value);
    }
    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        automatedMarketMakerPairs[pair] = value;
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    bool public launch = false;
    function setLaunch(bool flag) public{
        require(address(airdropAddr)==msg.sender,'only AirDrop');
        launch = flag;
    }
    bool public lpzongziEnabled = true;
    address public marketAddr = 0xe516c9C7924Efa19532Bf0e95eCD2647C5a16399;
    address public divAddr;
    address public lpAddr = 0x17823910106Eb4D6Fe8aE7f5cAe6e36F5d11d266;
    bool public addRewardOpen = false;

    function setAddRewardOpen(bool value) external onlyOwner{
        addRewardOpen = value;
    }

    function setMinAccountBalance(uint256 amount) external onlyOwner{
        minAccountBalance = amount;
    }

    function EmergeLaunch(bool flag) external onlyOwner{
        launch = flag;
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(amount > minAccountBalance,"Wrong Amount");
        if (!_excludedFees[from] && !_excludedFees[to]) {
            require(launch,'unlaunch');
            amount -= minAccountBalance;
            uint256 fees;
            uint256 totalFee = divFee + lpFee+ burnFee + marketFee;
            if (totalFee > 0) {  
                uint256 _totalFee = amount.mul(totalFee).div(100);
                super._transfer(from, address(this), _totalFee);
                fees += _totalFee;
            }
            if (to == uniswapPair) {
                uint256 contractBalance = balanceOf(address(this));
                if (!swapIng && contractBalance > minBalanceSwapToken) {
                    swapIng = true;
                    if (automatedMarketMakerPairs[to] &&
                        lpzongziEnabled &&
                        block.timestamp >= lastLpzongziTime + lpzongziFrequency &&
                        !_excludedFees[from]
                    ) {
                        autozongziLiquidityPairTokens();
                    }
                    uint256 beforeBalance = payable(address(this)).balance;
                    swapTokensForEth(contractBalance*85/100);
                    uint256 afterBalance = payable(address(this)).balance;
                    uint256 swapAmount = afterBalance - beforeBalance;
                    addLiquidity(contractBalance*15/100, swapAmount*15/85);
                    payable(marketAddr).transfer(swapAmount*30/85);
                    payable(divAddr).transfer(swapAmount*10/85);
                    if(addRewardOpen){
                        ILP(divAddr).addReward(swapAmount*10/85);
                    }
                    swapIng = false;
                }
            }
            
            if (fees > 0) {
                amount -= fees;
            }
        }
        super._transfer(from, to, amount);
    }

    function setAddrs(address _divAddr) external onlyOwner{
            divAddr = _divAddr;
    }


   function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        IERC20 token = IERC20(address(this));
        token.approve(address(uniswapRouter), tokenAmount);
        // add the liquidity
        uniswapRouter.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            lpAddr,
            block.timestamp
        );
    }


    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapRouter.WETH();
        _approve(address(this), address(uniswapRouter), tokenAmount);
        // make the swap
        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }
    uint256 public lpzongziFrequency = 3600 seconds;
    uint256 public lastLpzongziTime;
    uint256 public percentForLPzongzi = 75; // 25 = .25%
    function autozongziLiquidityPairTokens() internal returns (bool) {
        lastLpzongziTime = block.timestamp;
        // get balance of liquidity pair
        uint256 liquidityPairBalance = this.balanceOf(uniswapPair);
        // calculate amount to zongzi
        uint256 amountTozongzi = liquidityPairBalance.mul(percentForLPzongzi).div(
            10000
        );
        // pull tokens from pancakePair liquidity and move to dead address permanently
        if (amountTozongzi > 0) {
            super._transfer(uniswapPair, address(0xdead), amountTozongzi);
        }
        //sync price since this is not in a swap transaction!
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapPair);
        pair.sync();
        emit AutoNukeLP();
        return true;
    }
    event AutoNukeLP();

    function zongziToholder(address to,uint256 amount,uint256 balance)external{
        require(msg.sender == address(zongziHolder),'only zongzis');
        require(launch,'unlaunch');
        uint256 _amount = balanceOf(to);
        require(_amount >= amount,'not enough');
        super._transfer(to, address(zongziHolder), amount);
        uint256 _balance =payable(address(this)).balance;
        require(_balance >= balance, "Droped out");
        payable(address(zongziHolder)).transfer(balance);
    }
    //to recieve ETH from uniswapV2Router when swaping
    receive() external payable {}
}