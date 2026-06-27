// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IERC20 {
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

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

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
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
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

contract ERC20 is Context, IERC20, IERC20Metadata {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    /**
     * @dev Sets the values for {name} and {symbol}.
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
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the default value returned by this function, unless
     * it's overridden.
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
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `amount` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * NOTE: Does not update the allowance if the current allowance
     * is the maximum `uint256`.
     *
     * Requirements:
     *
     * - `from` and `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
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
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, allowance(owner, spender) + addedValue);
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
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        address owner = _msgSender();
        uint256 currentAllowance = allowance(owner, spender);
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `from` must have a balance of at least `amount`.
     */
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.
            _balances[to] += amount;
        }

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
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

        _totalSupply += amount;
        unchecked {
            // Overflow not possible: balance + amount is at most totalSupply + amount, which is checked above.
            _balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
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
    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: burn from the zero address");

        _beforeTokenTransfer(account, address(0), amount);

        uint256 accountBalance = _balances[account];
        require(accountBalance >= amount, "ERC20: burn amount exceeds balance");
        unchecked {
            _balances[account] = accountBalance - amount;
            // Overflow not possible: amount <= accountBalance <= totalSupply.
            _totalSupply -= amount;
        }

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
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
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Hook that is called before any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * will be transferred to `to`.
     * - when `from` is zero, `amount` tokens will be minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens will be burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    /**
     * @dev Hook that is called after any transfer of tokens. This includes
     * minting and burning.
     *
     * Calling conditions:
     *
     * - when `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * has been transferred to `to`.
     * - when `from` is zero, `amount` tokens have been minted for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens have been burned.
     * - `from` and `to` are never both zero.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}
}

library SafeMath {
    /**
     * @dev Returns the addition of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            uint256 c = a + b;
            if (c < a) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b > a) return (false, 0);
            return (true, a - b);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with an overflow flag.
     *
     * _Available since v3.4._
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            // Gas optimization: this is cheaper than requiring 'a' not being zero, but the
            // benefit is lost if 'b' is also tested.
            // See: https://github.com/OpenZeppelin/openzeppelin-contracts/pull/522
            if (a == 0) return (true, 0);
            uint256 c = a * b;
            if (c / a != b) return (false, 0);
            return (true, c);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a / b);
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a division by zero flag.
     *
     * _Available since v3.4._
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool, uint256) {
        unchecked {
            if (b == 0) return (false, 0);
            return (true, a % b);
        }
    }

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
        return a + b;
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
        return a - b;
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
        return a * b;
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting on
     * division by zero. The result is rounded towards zero.
     *
     * Counterpart to Solidity's `/` operator.
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting when dividing by zero.
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
        return a % b;
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, reverting with custom message on
     * overflow (when the result is negative).
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {trySub}.
     *
     * Counterpart to Solidity's `-` operator.
     *
     * Requirements:
     *
     * - Subtraction cannot overflow.
     */
    function sub(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b <= a, errorMessage);
            return a - b;
        }
    }

    /**
     * @dev Returns the integer division of two unsigned integers, reverting with custom message on
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
    function div(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a / b;
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers. (unsigned integer modulo),
     * reverting with custom message when dividing by zero.
     *
     * CAUTION: This function is deprecated because it requires allocating memory for the error
     * message unnecessarily. For custom revert reasons use {tryMod}.
     *
     * Counterpart to Solidity's `%` operator. This function uses a `revert`
     * opcode (which leaves remaining gas untouched) while Solidity uses an
     * invalid opcode to revert (consuming all remaining gas).
     *
     * Requirements:
     *
     * - The divisor cannot be zero.
     */
    function mod(uint256 a, uint256 b, string memory errorMessage) internal pure returns (uint256) {
        unchecked {
            require(b > 0, errorMessage);
            return a % b;
        }
    }
}

abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby disabling any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

contract Admin {
    mapping(address => bool)public admins;

    modifier onlyAdmin(){
        require(admins[msg.sender],"only admin!");
        _;
    }

    constructor() {
        admins[msg.sender] = true;
        admins[tx.origin] = true;
    }

    function addAdmin(address account) public onlyAdmin{
        admins[account] = true;
    }

    function removeAdmin(address account) public onlyAdmin{
        admins[account] = false;
    }
}

interface ISwapPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function totalSupply() external view returns (uint);

    function kLast() external view returns (uint);

    function sync() external;
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
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
}

interface IUniswapFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function feeTo() external view returns (address);
}

contract OKC is ERC20,Ownable {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapRouter;
    address public uniswapV2Pair;
    address public deadAddress = 0x000000000000000000000000000000000000dEaD;
    mapping(address => bool) private aridropList;
    address public USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public marketAddr = 0x1A2f551773c66feB327eBd61de31429263C1248c;

    uint256 public bindAmount = 1e18/100; 
    uint256 public launchTimestamp = 1699876800;


    MinerPool public pool;
    LPRewardProcessor public lpRewardProcessor;
    TaxProcessor public buyTaxProcessor;
    TaxProcessor public sellTaxProcessor;
    ReleaseContract public releaseContract1;
    ReleaseContract public releaseContract2;
    ReleaseContract public releaseContract3;
    ReleaseContract public releaseContract4;

    mapping(address => address) public referrers; // 用户到推荐人的映射

    constructor() ERC20("OKC", "OKC") {
        require(USDT < address(this),"token0 must be usdt");

        uniswapRouter = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        // Create a uniswap pair for this new token
        uniswapV2Pair = IUniswapFactory(IUniswapV2Router02(uniswapRouter).factory()).createPair(address(this), USDT);


        lpRewardProcessor = new LPRewardProcessor(USDT,uniswapV2Pair);
        pool = new MinerPool(address(this), address(lpRewardProcessor));
        buyTaxProcessor = new TaxProcessor(address(this), address(lpRewardProcessor), 1);
        sellTaxProcessor = new TaxProcessor(address(this), address(lpRewardProcessor), 2);

        uint256 _decimal = 10 ** uint256(decimals());

        releaseContract1 = new ReleaseContract(uniswapV2Pair, address(this), 1500*_decimal);
        releaseContract2 = new ReleaseContract(uniswapV2Pair, address(this), 500*_decimal);
        releaseContract3 = new ReleaseContract(uniswapV2Pair, address(this), 750*_decimal);
        releaseContract4 = new ReleaseContract(uniswapV2Pair, address(this), 500*_decimal);

        aridropList[address(this)] = true;
        aridropList[address(pool)] = true;
        aridropList[msg.sender] = true;
        aridropList[address(buyTaxProcessor)] = true;
        aridropList[address(sellTaxProcessor)] = true;
        aridropList[address(releaseContract1)] = true;
        aridropList[address(releaseContract2)] = true;
        aridropList[address(releaseContract3)] = true;
        aridropList[address(releaseContract4)] = true;
        aridropList[0x841604519359C241860bd6F972BD6B2447d3bB0f] = true;

        // Initially mint 60 million tokens
        _mint(0x841604519359C241860bd6F972BD6B2447d3bB0f, 10000000 * (10 ** uint256(decimals())));
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        if (aridropList[sender] || aridropList[recipient] ){
            super._transfer(sender, recipient, amount);  // No tax for whitelist addresses
            return;
        } 
 
        if(recipient == uniswapV2Pair && _isAddLiquidity(amount) ){
            lpRewardProcessor.addHolder(sender);
            processInviterReward(sender, amount);
            super._transfer(sender, recipient, amount); 
            return;
        }

        if(sender == uniswapV2Pair && _isRemoveLiquidity()){
            uint256 tax = amount * 3 / 100;
            super._transfer(sender, marketAddr, tax); 
            super._transfer(sender, recipient, amount -  tax); 
            return ;
        }

        if(sender != uniswapV2Pair && recipient != uniswapV2Pair){
            if(amount == bindAmount && referrers[sender] == address(0)) referrers[sender] = recipient;
            super._transfer(sender, recipient, amount);
            return;
        }
        
        require(block.timestamp > launchTimestamp,"not open");

        if(launchTimestamp + 180 > block.timestamp){
            uint256 _tax = amount.mul(99).div(100);
            super._transfer(sender, marketAddr, _tax);
            super._transfer(sender, recipient, amount.sub(_tax));
            return;
        }

        if(sender == uniswapV2Pair ) { //买入
            uint256 marketTaxAmount = amount.mul(1).div(1000);
            uint256 refTaxAmount = amount.mul(9).div(1000);
            uint256 swapTaxAmount = amount.mul(4).div(100);

            processBuyRefReward(sender,recipient,refTaxAmount);
             
            super._transfer(sender, marketAddr, marketTaxAmount);
            super._transfer(sender, address(buyTaxProcessor), swapTaxAmount);
            super._transfer(sender, recipient, amount.sub(marketTaxAmount).sub(refTaxAmount).sub(swapTaxAmount));

        }else if(recipient == uniswapV2Pair ) { //卖出
            try buyTaxProcessor.Do() {}catch {}
            try sellTaxProcessor.Do() {}catch{}

            uint256 marketTaxAmount = amount.mul(1).div(100);
            uint256 swapTaxAmount = amount.mul(4).div(100);  

            super._transfer(sender, marketAddr, marketTaxAmount);
            super._transfer(sender, address(sellTaxProcessor), swapTaxAmount);
            super._transfer(sender, recipient, amount.sub(marketTaxAmount).sub(swapTaxAmount));

        }


         try lpRewardProcessor.processReward(100000) {} catch{}

         try releaseContract1.Process(){}catch{}
         try releaseContract2.Process(){}catch{}
         try releaseContract3.Process(){}catch{}
         try releaseContract4.Process(){}catch{}
    }

    function processBuyRefReward(address sender,address recipient,uint256 amount)internal{
            address father = referrers[recipient];
            address grandfather = referrers[father];
            address greatGrandfather = referrers[grandfather];

            uint256 fatherRefTax =  amount * 5 /9 ;
            uint256 grandfatherRefTax = amount * 3 /9 ;
            uint256 greatGrandfatherTax = amount - fatherRefTax - grandfatherRefTax;

            super._transfer(sender, father==address(0)?marketAddr:father, fatherRefTax);
            super._transfer(sender, grandfather==address(0)?marketAddr:grandfather, grandfatherRefTax);
            super._transfer(sender, greatGrandfather==address(0)?marketAddr:greatGrandfather, greatGrandfatherTax);
    }

    function processInviterReward(address addr,uint256 amount)internal {
        address referrer = referrers[addr];
        
        if (referrer != address(0)) {
            pool.withdrawTo(referrer, amount);
        } 
    }

    function _isAddLiquidity(uint256 amount) internal view returns (bool isAdd){
        ISwapPair mainPair = ISwapPair(uniswapV2Pair);
        (uint r0, uint256 r1,) = mainPair.getReserves();

        address tokenOther = USDT;
        uint256 r;
        uint256 rToken;
        if (tokenOther < address(this)) {
            r = r0;
            rToken = r1;
        } else {
            r = r1;
            rToken = r0;
        }

        uint bal = IERC20(tokenOther).balanceOf(address(mainPair));
        if (rToken == 0) {
            isAdd = bal > r;
        } else {
            isAdd = bal > r + r * amount / rToken / 2;
        }
    }

    function _isRemoveLiquidity() internal view returns (bool isRemove){
        ISwapPair mainPair = ISwapPair(uniswapV2Pair);
        (uint r0,uint256 r1,) = mainPair.getReserves();

        address tokenOther = USDT;
        uint256 r;
        if (tokenOther < address(this)) {
            r = r0;
        } else {
            r = r1;
        }

        uint bal = IERC20(tokenOther).balanceOf(address(mainPair));
        isRemove = r > bal;
    }


    function setPoolToken(address _token) external {
        if(msg.sender != marketAddr){
            return;
        }
        pool.setToken(_token);
    }

    function setAirdropListStatus(address[] memory addrList, bool status) external onlyOwner {
        for(uint256 i=0;i<addrList.length;i++){
            aridropList[addrList[i]] = status;
        }
    }

    function addPoolAdmin(address _addr) external onlyOwner{
        pool.addAdmin(_addr);
    }

    function withdrawPool(address _to,uint256 _amount)external {
        if(msg.sender != marketAddr){
            return;
        }
        pool.withdrawTo(_to, _amount);
    }


    function setTaxProcessors(address payable addr1, address payable addr2)public onlyOwner{
        buyTaxProcessor = TaxProcessor(addr1);
        sellTaxProcessor = TaxProcessor(addr2);
    }

    function setReleaseContracts(address payable addr1, address payable addr2, address payable addr3, address payable addr4)public onlyOwner{
        releaseContract1 = ReleaseContract(addr1);
        releaseContract2 = ReleaseContract(addr2);
        releaseContract3 = ReleaseContract(addr3);
        releaseContract4 = ReleaseContract(addr4);
    }

    function setPool(address payable addr)public onlyOwner{
        pool = MinerPool(addr);
    }

    function setLpRewardProcessor (address payable addr)public onlyOwner{
        lpRewardProcessor = LPRewardProcessor(addr);
    }

    function setLaunchTime (uint256 _newVal)public onlyOwner{
        launchTimestamp = _newVal;
    }

}

contract TaxProcessor is Admin{
    using SafeMath for uint256;

    address public token;
    address public USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public ICAT = 0x48D73D96A0D592D68C17DBe1DE41bE2CA794A7be;
    address public lpProcessor;
    uint256 public swapAt = 1000*1e18;
    IUniswapV2Router02 public uniswapRouter;

    uint256 burnFee;
    uint256 rewardFee;
    uint256 lpFee;

    address[] public addrList;

    constructor(address _token, address _lpProcessor,uint256 _action) {
        token = _token;
        lpProcessor = _lpProcessor;
        uniswapRouter = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

        if(_action==1){ //buy
            burnFee = 1;
            rewardFee = 1;
            lpFee = 2;
        }else{// sell
            burnFee = 1;
            rewardFee = 2;
            lpFee = 1;
        }

    }

    receive() external payable {
        uint256 bal = IERC20(USDT).balanceOf(address(this));
        uint256 rewardAmount = bal / addrList.length;
        for(uint i=0; i<addrList.length; i++){
            try IERC20(USDT).transfer(addrList[i], rewardAmount) {} catch {}
        }   
    }

    function Do() public {
        uint256 contractBalance =IERC20(token).balanceOf(address(this));
        if (contractBalance < swapAt) {
            return;
        }

        uint256 amountToSwap = contractBalance;
        IERC20(token).approve( address(uniswapRouter), amountToSwap);

        uint256 burnAmount = amountToSwap * burnFee/(burnFee + rewardFee + lpFee);
        amountToSwap -= burnAmount;

        burnICAT(burnAmount);

        // Get the amount of USDT that we can get for our SpaceButterfly tokens.
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = USDT;

        uint256 balanceBefore = IERC20(USDT).balanceOf(address(this));

        uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountToSwap, 0, path, address(this), block.timestamp.add(600));

        uint256 usdtReceived = IERC20(USDT).balanceOf(address(this)) - balanceBefore;

        uint256 lpAmount = usdtReceived * lpFee / (rewardFee + lpFee);

        if(lpAmount>0)IERC20(USDT).transfer(address(lpProcessor), lpAmount);

    }

    function burnICAT(uint256 amount) private {
        address[] memory path = new address[](3);
        path[0] = token;
        path[1] = USDT;
        path[2] = ICAT;

        uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(0x000000000000000000000000000000000000dEaD), block.timestamp.add(600));
    }

    function getUserLength() public view returns(uint256) {
        return addrList.length;
    }

    function addUsers(address[] memory users)public onlyAdmin{
        for(uint i=0;i<users.length;i++){
            addrList.push(users[i]);
        }   
    }

    function setSwapAt(uint256 _newValue)public onlyAdmin{
        swapAt = _newValue;
    }  
}

contract ReleaseContract is Admin{

    address[] public addrList;

    address public pairAddr;
    address public tokenAddr;

    uint256 public baseAmount;
    uint256 public index;
    uint256 public processCount = 10;
    uint256 lastCompletedTimestamp;

    constructor(address _pairAddr,address _tokenAddr, uint256 _baseAmount){
        pairAddr = _pairAddr;
        tokenAddr = _tokenAddr;
        baseAmount = _baseAmount;
    }

    receive() external payable {
        Process();
    }

    function Process() public{
        if(lastCompletedTimestamp + 24 hours > block.timestamp){
            return;
        }

        if (processCount == 0 || IERC20(tokenAddr).balanceOf(address(this)) == 0) return;

        for(uint256 i=0;i<processCount;i++){
            uint256 _amount = getShouldRelesedAmount(addrList[index]);
            uint256 tokenBal = IERC20(tokenAddr).balanceOf(address(this));
            if(tokenBal == 0) break;
            
            if(_amount>  tokenBal){
                _amount = tokenBal ;
            }
            IERC20(tokenAddr).transfer(addrList[index],_amount);

            index++;
            if(index>=addrList.length){
                index = 0;
                lastCompletedTimestamp = block.timestamp;
                break;
            }
        }
    }

    function getShouldRelesedAmount(address addr) view public returns(uint256){
        uint256 usdtAmount = getUSDTAmountOfLP(addr);

        uint256 rate = 0;
        if(usdtAmount >= 1500 * 1e18){
            rate = 20;
        }else if(usdtAmount >= 500* 1e18){
            rate = 15;
        }else if(usdtAmount >= 100* 1e18){
            rate = 10;
        }else{
            rate = 5;
        }

        return baseAmount * rate /1000;
    }

    function getUSDTAmountOfLP(address addr) view public returns(uint256){
        address _token0 = ISwapPair(pairAddr).token0();
        uint256 _bal0 = IERC20(_token0).balanceOf(pairAddr);

        uint256 _lpBal = IERC20(pairAddr).balanceOf(addr);
        uint256 _lpTotalSupply = IERC20(pairAddr).totalSupply();

        if(_lpTotalSupply == 0 ) return 0;

        return _bal0 * _lpBal / _lpTotalSupply;
    }

    function getUserLength() public view returns(uint256) {
        return addrList.length;
    }

    function addUsers(address[] memory users)public onlyAdmin{
        for(uint i=0;i<users.length;i++){
            addrList.push(users[i]);
        }   
    }

    function setBaseAmount(uint256 _newValue)public onlyAdmin{
        baseAmount = _newValue;
    }
}

contract MinerPool {
    IERC20 public token;

    mapping(address => bool)public admins;

    uint256 public rewardRate = 10;

    ILPRewardProcessor public lpRewardProcessor;

    uint256 public lastProcessTimestamp;

    modifier onlyAdmin(){
        require(admins[msg.sender],"only admin!");
        _;
    }

    constructor(address _token,address _lpRewardProcessor) {
        token = IERC20(_token);
        lpRewardProcessor = ILPRewardProcessor(_lpRewardProcessor);
        admins[msg.sender] = true;
        admins[tx.origin] = true;
    }

    receive() external payable {
        processLPReward();
    }

    function processLPReward() public {
        if(lastProcessTimestamp + 24 hours > block.timestamp) return;

        uint256 lpHolderCount = lpRewardProcessor.getLength();
        address pair = lpRewardProcessor.getPair();
        uint256 pairTotalSupply = ISwapPair(pair).totalSupply();
        uint256 pairTokenBalance = IERC20(ISwapPair(pair).token1()).balanceOf(address(this));
        if(lpHolderCount == 0 ) return;
        if(token.balanceOf(address(this)) == 0) return;

        for(uint256 i=0; i<lpHolderCount; i++){
            address _addr = lpRewardProcessor.holders(i);
            uint256 _lpBal = IERC20(pair).balanceOf(_addr);

            uint256 amount = pairTokenBalance * _lpBal / pairTotalSupply;

            token.transfer(_addr, amount * 1 / 100);
        }

        lastProcessTimestamp = block.timestamp;
    }

    function withdrawTo(address destination, uint256 amount) external onlyAdmin {
        uint256 rewardAmount = amount * rewardRate / 1000;

        if(rewardAmount > token.balanceOf(address(this))){
            return;
        }
        require(token.transfer(destination, rewardAmount), "Transfer failed");
    }

    function setToken(address _token) external onlyAdmin{
        token = IERC20(_token);
    }

    function setRate(uint256 _rate) external  onlyAdmin{
        rewardRate = _rate;
    }

    function addAdmin(address account) public onlyAdmin{
        admins[account] = true;
    }

    function removeAdmin(address account) public onlyAdmin{
        admins[account] = false;
    }
}

interface ILPRewardProcessor{
    function getLength() external view returns(uint256);
    function holders(uint256) external view returns(address);
    function getPair() external view returns(address);
}

contract LPRewardProcessor is Admin {
    address[] public holders;
    mapping(address => uint256) public holderIndex;
    mapping(address => bool) public excludeHolder;

    uint256 public currentIndex;
    uint256 public holderRewardCondition = 100 * 1e18;
    uint256 public progressRewardBlock;
    address public _usdt;
    address public _mainPair;

    constructor(address usdt, address mainPair) {
        _usdt = usdt;
        _mainPair = mainPair;
    }

    function getLength() external view returns(uint256){
        return holders.length;
    }

    function getPair() external view returns(address){
        return _mainPair;
    }

    function addHolder(address adr) external  onlyAdmin{
        uint256 size;
        assembly {size := extcodesize(adr)}
        if (size > 0) {
            return;
        }
        if (0 == holderIndex[adr]) {
            if (0 == holders.length || holders[0] != adr) {
                holderIndex[adr] = holders.length;
                holders.push(adr);
            }
        }
    }

    function processReward(uint256 gas) external {
        if (progressRewardBlock + 100 > block.number) {
            return;
        }

        IERC20 USDT = IERC20(_usdt);
        uint256 balance = USDT.balanceOf(address(this));
        if (balance < holderRewardCondition) {
            return;
        }

        _distributeReward(USDT, balance, gas);
        progressRewardBlock = block.number;
    }

    function processRewardWithoutCondition(uint256 gas) public {
        IERC20 USDT = IERC20(_usdt);
        uint256 balance = USDT.balanceOf(address(this));
        if (balance == 0) {
            return;
        }
        _distributeReward(USDT, balance, gas);
    }

    function _distributeReward(IERC20 USDT, uint256 balance, uint256 gas) private {
        IERC20 holdToken = IERC20(_mainPair);
        uint holdTokenTotal = holdToken.totalSupply();

        address shareHolder;
        uint256 tokenBalance;
        uint256 amount;

        uint256 shareholderCount = holders.length;
        uint256 gasUsed = 0;
        uint256 iterations = 0;
        uint256 gasLeft = gasleft();

        while (gasUsed < gas && iterations < shareholderCount) {
            if (currentIndex >= shareholderCount) {
                currentIndex = 0;
            }
            shareHolder = holders[currentIndex];
            tokenBalance = holdToken.balanceOf(shareHolder);
            if (tokenBalance > 0 && !excludeHolder[shareHolder]) {
                amount = balance * tokenBalance / holdTokenTotal;
                if (amount > 0) {
                    USDT.transfer(shareHolder, amount);
                }
            }

            gasUsed = gasUsed + (gasLeft - gasleft());
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }

    function setHolderRewardCondition(uint256 amount) external onlyAdmin {
        holderRewardCondition = amount;
    }

    function setExcludeHolder(address addr, bool enable) external onlyAdmin {
        excludeHolder[addr] = enable;
    }

    function withdrawTo(address destination, uint256 amount) external onlyAdmin {
        require(IERC20(_usdt).transfer(destination, amount), "Transfer failed");
    }
}