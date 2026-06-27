// SPDX-License-Identifier: unlicensed

// File @openzeppelin/contracts/interfaces/draft-IERC6093.sol@v5.0.2


// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/draft-IERC6093.sol)
pragma solidity ^0.8.20;

/**
 * @dev Standard ERC20 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC20 tokens.
 */
interface IERC20Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC20InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC20InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `spender`’s `allowance`. Used in transfers.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     * @param allowance Amount of tokens a `spender` is allowed to operate with.
     * @param needed Minimum amount required to perform a transfer.
     */
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC20InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `spender` to be approved. Used in approvals.
     * @param spender Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC20InvalidSpender(address spender);
}

/**
 * @dev Standard ERC721 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC721 tokens.
 */
interface IERC721Errors {
    /**
     * @dev Indicates that an address can't be an owner. For example, `address(0)` is a forbidden owner in EIP-20.
     * Used in balance queries.
     * @param owner Address of the current owner of a token.
     */
    error ERC721InvalidOwner(address owner);

    /**
     * @dev Indicates a `tokenId` whose `owner` is the zero address.
     * @param tokenId Identifier number of a token.
     */
    error ERC721NonexistentToken(uint256 tokenId);

    /**
     * @dev Indicates an error related to the ownership over a particular token. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param tokenId Identifier number of a token.
     * @param owner Address of the current owner of a token.
     */
    error ERC721IncorrectOwner(address sender, uint256 tokenId, address owner);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC721InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC721InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param tokenId Identifier number of a token.
     */
    error ERC721InsufficientApproval(address operator, uint256 tokenId);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC721InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC721InvalidOperator(address operator);
}

/**
 * @dev Standard ERC1155 Errors
 * Interface of the https://eips.ethereum.org/EIPS/eip-6093[ERC-6093] custom errors for ERC1155 tokens.
 */
interface IERC1155Errors {
    /**
     * @dev Indicates an error related to the current `balance` of a `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     * @param balance Current balance for the interacting account.
     * @param needed Minimum amount required to perform a transfer.
     * @param tokenId Identifier number of a token.
     */
    error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId);

    /**
     * @dev Indicates a failure with the token `sender`. Used in transfers.
     * @param sender Address whose tokens are being transferred.
     */
    error ERC1155InvalidSender(address sender);

    /**
     * @dev Indicates a failure with the token `receiver`. Used in transfers.
     * @param receiver Address to which tokens are being transferred.
     */
    error ERC1155InvalidReceiver(address receiver);

    /**
     * @dev Indicates a failure with the `operator`’s approval. Used in transfers.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     * @param owner Address of the current owner of a token.
     */
    error ERC1155MissingApprovalForAll(address operator, address owner);

    /**
     * @dev Indicates a failure with the `approver` of a token to be approved. Used in approvals.
     * @param approver Address initiating an approval operation.
     */
    error ERC1155InvalidApprover(address approver);

    /**
     * @dev Indicates a failure with the `operator` to be approved. Used in approvals.
     * @param operator Address that may be allowed to operate on tokens without being their owner.
     */
    error ERC1155InvalidOperator(address operator);

    /**
     * @dev Indicates an array length mismatch between ids and values in a safeBatchTransferFrom operation.
     * Used in batch transfers.
     * @param idsLength Length of the array of token identifiers
     * @param valuesLength Length of the array of token amounts
     */
    error ERC1155InvalidArrayLength(uint256 idsLength, uint256 valuesLength);
}


// File @openzeppelin/contracts/token/ERC20/IERC20.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
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
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
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
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}


// File @openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.20;

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 */
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


// File @openzeppelin/contracts/utils/Context.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.1) (utils/Context.sol)

pragma solidity ^0.8.20;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}


// File @openzeppelin/contracts/token/ERC20/ERC20.sol@v5.0.2

// Original license: SPDX_License_Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (token/ERC20/ERC20.sol)

pragma solidity ^0.8.20;




/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.openzeppelin.com/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * The default value of {decimals} is 18. To change this, you should override
 * this function so it returns a different value.
 *
 * We have followed general OpenZeppelin Contracts guidelines: functions revert
 * instead returning `false` on failure. This behavior is nonetheless
 * conventional and does not conflict with the expectations of ERC20
 * applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 */
abstract contract ERC20 is Context, IERC20, IERC20Metadata, IERC20Errors {
    mapping(address account => uint256) private _balances;

    mapping(address account => mapping(address spender => uint256)) internal _allowances;

    uint256 private _totalSupply;

    string public  _name;
    string public _symbol;

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
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
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
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - the caller must have a balance of at least `value`.
     */
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * NOTE: If `value` is the maximum `uint256`, the allowance is not updated on
     * `transferFrom`. This is semantically equivalent to an infinite approval.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
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
     * - `from` must have a balance of at least `value`.
     * - the caller must have allowance for ``from``'s tokens of at least
     * `value`.
     */
    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to`.
     *
     * This internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _transfer(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    /**
     * @dev Transfers a `value` amount of tokens from `from` to `to`, or alternatively mints (or burns) if `from`
     * (or `to`) is the zero address. All customizations to transfers, mints, and burns should be done by overriding
     * this function.
     *
     * Emits a {Transfer} event.
     */
    function _update(address from, address to, uint256 value) internal virtual {
        if (from == address(0)) {
            // Overflow check required: The rest of the code assumes that totalSupply never overflows
            _totalSupply += value;
        } else {
            uint256 fromBalance = _balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                // Overflow not possible: value <= fromBalance <= totalSupply.
                _balances[from] = fromBalance - value;
            }
        }

        if (to == address(0)) {
            unchecked {
                // Overflow not possible: value <= totalSupply or value <= fromBalance <= totalSupply.
                _totalSupply -= value;
            }
        } else {
            unchecked {
                // Overflow not possible: balance + value is at most totalSupply, which we know fits into a uint256.
                _balances[to] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /**
     * @dev Creates a `value` amount of tokens and assigns them to `account`, by transferring it from address(0).
     * Relies on the `_update` mechanism
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead.
     */
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /**
     * @dev Destroys a `value` amount of tokens from `account`, lowering the total supply.
     * Relies on the `_update` mechanism.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * NOTE: This function is not virtual, {_update} should be overridden instead
     */
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /**
     * @dev Sets `value` as the allowance of `spender` over the `owner` s tokens.
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
     *
     * Overrides to this logic should be done to the variant with an additional `bool emitEvent` argument.
     */
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /**
     * @dev Variant of {_approve} with an optional flag to enable or disable the {Approval} event.
     *
     * By default (when calling {_approve}) the flag is set to true. On the other hand, approval changes made by
     * `_spendAllowance` during the `transferFrom` operation set the flag to false. This saves gas by not emitting any
     * `Approval` event during `transferFrom` operations.
     *
     * Anyone who wishes to continue emitting `Approval` events on the`transferFrom` operation can force the flag to
     * true using the following override:
     * ```
     * function _approve(address owner, address spender, uint256 value, bool) internal virtual override {
     *     super._approve(owner, spender, value, true);
     * }
     * ```
     *
     * Requirements are the same as {_approve}.
     */
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `value`.
     *
     * Does not update the allowance value in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Does not emit an {Approval} event.
     */
    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }
}


// File contracts/iVestDAObsc3.sol

// Original license: SPDX_License_Identifier: unlicensed
pragma solidity ^0.8.2;
interface IUniswapV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function feeTo() external view returns (address);
    function feeToSetter() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}


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
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
    external returns (uint[] memory amounts);

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

interface IUniswapV2Router02 is IUniswapV2Router01 {    
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external returns (uint amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}


/// @title iVest DAO - An antifragile deflationary ecosystem. 
contract iVESTDAO is ERC20 {
    address public owner;   

    mapping (address => uint256) private _rOwned;
    mapping (address => uint256) private _tOwned;
    mapping (address => uint256) public karma;
    mapping (address => bool) private _isExcludedFromFee;
    mapping (address => bool) private _isExcluded;
    address[] private _excluded;

    event AwardKarma(address donator, uint256 donationRewards);
    event SpendKarma(address donator, uint256 karmaSpent);
    event TransferKarma(address sender, address receiver, uint256 karmaSent);
    event DAOMessageEvent(string message,address from, address to);
    event DAOWalletRegistration(address wallet, uint256 level);
    event NewVestingEntry (address recipient,uint256 vestingAmount,uint256 startTime,uint256 fullyVestedTime);
    event ClearedVestingEntry (address wallet,uint256 logsCleared);
    event NewDonation (address donator, string donationType, uint256 amount);
    event tipSent(address sender, address recipient, string message, uint256 amount,uint256 karmaSent);


    // Vesting
    struct VestingSchedule {
        uint256 amount;
        uint256 startTime;
    }
          

    mapping(address => uint256) public walletRegistrationStatus;//[0.Unregistered,1.Registered,2.Contributor,3.Leader,4.DAO,5.Exchange,6.Other]
    mapping(address => VestingSchedule[]) public vestingSchedules;

    function migrateOnBoardBalances(address account, uint256 balance)public{
        require(address(msg.sender)==admin||address(msg.sender)==DAOwallet);
         _tokenTransfer(owner,account,balance,false);
    }

    function revealVestedBalances(address _address) external view returns (uint256){
        return tokenFromReflection(_rOwned[_address]);
    }

    function tip(address recipient) public  {
        //Overload function simple tipping. Transfers _standardTipAmount iVest tokens. Default is 10.
        tipLike( recipient, _standardTipAmount, 0);
    }

    function like(address recipient) public  {
        //Overload function simple liking. Awards _standardLikeAmount karma. Default is 10.
        tipLike( recipient, 0, _standardLikeAmount);
    }

    function gratuity(address recipient,string memory _message, uint256 amount, uint256 _karma)public{
        //Send a small amount of iVest, between 1 and 10,000, with no transaction fee. Or karma (1 to 10,000)
        //Includes a brief message.
        tipLike( recipient, amount, _karma);
        iVestMessenger(_message, recipient);
    }

    function tipLike(address recipient, uint256 amount, uint256 _karma) public {
        //Send a small amount of iVest, between 1 and 10,000, with no transaction fee. Or karma (1 to 10,000)
        //Ensure either tokens or karma is being sent
        require(amount > 0 || _karma > 0, "Must send tokens or karma");

        
        if (amount > 0) {
            require(amount >= 10000 && amount <= 100000000, "Amount must be between 1 and 10,000 iVest units (scaled by 10000)");
        }

        
        if (_karma > 0) {
            require(_karma >= 1 && _karma <= 10000, "Karma must be between 1 and 10,000 units");
        }

        
        if (amount > 0) {_tokenTransfer(msg.sender, recipient, amount, false);}
        
        if (_karma > 0) {Karma_Transfer(recipient, _karma);}

        // Emit the tipSent event
        emit tipSent(msg.sender, recipient, "tip,like", amount, _karma);
    }

    function iVestMessenger(string memory _message) public  {
        //Overload function for general chat messages, when the recipient isnt specified, it should be directed to the null address.
        iVestMessenger(_message, address(0));
    }

    function iVestMessenger(string memory _message, address recipient) public {
        //Sanitize Input
        require(validateString(_message), "Invalid string, only alphanumeric characters and punctuation. 256 character limit.");
        
        //Require the sender hold at least 1.0 iVest tokens or be a special (excluded) address
        require((balanceOf(address(msg.sender)) >= 10000) || (_isExcluded[address(msg.sender)]) || (address(msg.sender)==owner)  || (address(msg.sender)==admin) ,"iVest: You must hold iVest tokens to send blockchain messages.");

        //pay a cost if enabled
        if ((iVestMessengerFee>0) && (!_isExcluded[address(msg.sender)])){
            uint256 fee = iVestMessengerFee;
            
            if (walletRegistrationStatus[(msg.sender)] >= 1){
                fee /=2;
            }
            _tokenTransfer(address(msg.sender),DAOwallet,fee,false);
            _tFeeTotal[2]+=fee;//[0.Vesting,1.Liquidity,2.DAO,3.BURN]
        }

        emit DAOMessageEvent(_message,address(msg.sender),recipient);
    }


    function validateString(string memory _str) internal view returns (bool) {
        bytes memory strBytes = bytes(_str);
        uint256 maxLength = walletRegistrationStatus[(msg.sender)] >= 2 ? 512 : 256;
        // limit the maximum length of the string
        if (strBytes.length > maxLength || strBytes.length == 0) {
            return false;
        }
    
        // limit characters 
        for (uint256 i = 0; i < strBytes.length; i++) {
            bytes1 char = strBytes[i];
            if (
                !(char >= 0x30 && char <= 0x39) && // 0-9
                !(char >= 0x41 && char <= 0x5A) && // A-Z
                !(char >= 0x61 && char <= 0x7A) && // a-z
                !(char == 0x20) &&                 // space
                !(char == 0x2C) &&                 // comma (,)
                !(char == 0x2E) &&                 // period (.)
                !(char == 0x21) &&                 // exclamation mark (!)
                !(char == 0x3F) &&                 // question mark (?)
                !(char == 0x40) &&                 // at symbol (@)
                !(char == 0x23) &&                 // hash symbol (#)
                !(char == 0x27) &&                 // apostrophe (')
                //Sender must be at least a level 2 contributor to send links.
                !(walletRegistrationStatus[(msg.sender)] >= 2 &&
                    (char == 0x3A || char == 0x2F)) // colon (:) and slash (/)
            ) {
                return false;
            }
        }
        return true;
    }


    function toggleWhaleFee(bool onOff)public{
        require(address(msg.sender)==owner ||address(msg.sender)==DAOwallet);
        takeWhaleDonations=onOff;
    }

    function selfRegisterWalletToggle(address wallet)public {
        //Sets an unregistered wallet to registered. Or takes a previously registered wallet, at any level, and unregisters it.
        require(address(msg.sender)==wallet);
        if (walletRegistrationStatus[wallet] == 0){
            walletRegistrationStatus[wallet] =1;
            emit DAOWalletRegistration (wallet, 1);
        } else {
            //Unregister
            walletRegistrationStatus[wallet] = 0;
            emit DAOWalletRegistration (wallet, 0);
        }
    }

    function DAOPromoteWallet(address wallet, uint256 level)public {
        //Sets an unregistered wallet to registered. Or takes a previously registered wallet, at any level, and unregisters it.
        require(address(msg.sender)==owner ||address(msg.sender)==DAOwallet || (address(msg.sender)==admin) );
        walletRegistrationStatus[wallet] =level;
        emit DAOWalletRegistration (wallet, level);
    }

    function addVestingSchedule(address _address, uint256 _amount, uint256 _startTime) private {
        VestingSchedule memory newData = VestingSchedule({
            amount: _amount,
            startTime: _startTime
        });

        if (_address == _vestingpool){
            vestingSchedules[_address].push(newData);
        }

        if (vestingSchedules[_address].length==0){
            vestingSchedules[_address].push(newData);
            uint256 vEntries = vestingSchedules[_vestingpool].length-1;
            vestingSchedules[_vestingpool][vEntries].amount+=_amount;
            return;
        }

        for (uint256 i = 0; i < vestingSchedules[_address].length; i++) {
            //find the first empty entry and use it
            if (vestingSchedules[_address][i].amount == 0 && vestingSchedules[_address][i].startTime == 0) {
                vestingSchedules[_address][i].amount = _amount;
                vestingSchedules[_address][i].startTime = _startTime;
                uint256 vEntries1 = vestingSchedules[_vestingpool].length-1;
                vestingSchedules[_vestingpool][vEntries1].amount+=_amount;
                return;
            }
        } 
        
        vestingSchedules[_address].push(newData);
        uint256 vEntries2 = vestingSchedules[_vestingpool].length-1;
        vestingSchedules[_vestingpool][vEntries2].amount+=_amount;
    }

    // Addresses 
    address public _liquiditypool= 0x624B57FF42683F1C4582B55495A65D1B09654282;
    address public LiquidityShield = 0x6E801db20b180E267cd1f2A01d27763B68B54e53;
    address public DAOwallet = 0x0CaB1Cd11967a95Edb7331e00c2c328eF0a4D344;
    address public _vestingpool = 0x1CC65aCC1ECf788D61981c6972B7832CA81d6cB4;
    address public admin;  

    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 10000000000000;//MAX SUPPLY
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256[4] private _tFeeTotal;//[0.Vesting,1.Liquidity,2.DAO,3.BURN]

    uint8 private _decimals = 4;
    uint256 public _transferFee = 0;

    uint256 public _taxFee = 3;//3% for vesting pool.
    uint256 private _previousTaxFee = _taxFee;
    uint256 public _daoFee = 3; //3% for DAO ecosystem, is collected with the LIQUIDITY FEE
    uint256 private _previousDaoFee = _daoFee;
    uint256 public _liquidityFee = 3; //3% for liqudity pool
    uint256 private _previousLiquidityFee = _liquidityFee;


    uint256 public _burnFee = 1; //1% for burn, ensuring deflationary pressure.
    uint256 private _previousBurnFee = _burnFee;

    bool private takeWhaleDonations = true;
    uint256 public _whaleDonationFee = 3; //3% for whale donations, split between LP and Vesting.
    uint256 public _totalVestingTime = 30 days;
    uint256 public _maxVestingEntries = 30; 
    uint256 public _vestingEntriesToClear = 30; //how many vesting entries to attempt to clear at once. Default is max.
    uint256 public _confirmationsBuffer = 15; //Wallets will report your vested balance [X] blocks behind the current block. prevents double spend, shenanigans.
    uint256 iVestMessengerFee = 100000;
    IUniswapV2Router02 public uniswapV2Router; //immutable
    address public uniswapV2Pair;
    
    uint256 public _minPurchaseAmount = 1000000; 
    uint256 public _maxTxAmount = 100000000000;//10 million or 1% of MAX supply.
    uint256 public _WhaleThreshold = 100000000000;//10 million or 1% of MAX supply.
                                      
    uint256 public _standardTipAmount = 100000;
    uint256 public _standardLikeAmount = 10;
    bool public _MASTER_TRANSFERS_ENABLED = true;
    bool public _MASTER_WALLETSCANTRADE_FLAG = true;

    constructor () ERC20("iVest DAO","iVest") {
        _rOwned[msg.sender] = _rTotal;
         owner = msg.sender;
        
        
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E); 
         // Create a uniswap pair for this new token
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        // set the rest of the contract variables
        uniswapV2Router = _uniswapV2Router;

        //Update LP directly after pair is created (MAINNET ONLY)
        updateLPAddress(uniswapV2Pair);
        

        //exclude owner, contract, special addresses and this contract from fee
        excludeFromFee(owner);
        excludeFromFee(address(this));
        excludeFromFee(_vestingpool);
        excludeFromFee(DAOwallet);
        excludeFromFee(LiquidityShield);
        

        excludeFromReward(address(this));
        excludeFromReward(address(_vestingpool));
        excludeFromReward(address(DAOwallet));
        excludeFromReward(address(LiquidityShield));
      
        emit Transfer(address(0), msg.sender, _tTotal); 
        addVestingSchedule(_vestingpool, uint256(0), block.timestamp);

        excludeFromReward(owner); 
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function updateLPAddress(address account) public {
    require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        //Update variables
        _liquiditypool = account;
        //UPDATE FLAGS
        excludeFromReward(_liquiditypool);
        excludeFromFee(_liquiditypool);
    }

    function onboardExchange(address exchangeAddress)public {
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        walletRegistrationStatus[exchangeAddress]=5; 
        excludeFromReward(exchangeAddress);
        excludeFromFee(exchangeAddress);
    }

    function balanceOf(address account) public view override returns (uint256) {
       uint256 vBalance=0;
       if (_isExcluded[account]) return _tOwned[account];   

        // Calculate vested balance
        VestingSchedule[] memory vestLog = vestingSchedules[account];
        
        uint256 totalAmount =0;

        if (vestLog.length >0) {
        

            for (uint32 i = 0; i < vestLog.length;i++){
            uint256 timeSinceStart = block.timestamp - vestLog[i].startTime;
           
           //Accomodate for pancakeswap slippage.
           if (i==vestLog.length-1){
                if (block.timestamp<= vestLog[i].startTime){
                    totalAmount += vestLog[i].amount;
                    vBalance += vestLog[i].amount;
                    continue;
                }
           }
        
           //Account for _confirmationsBuffer margin
           if (timeSinceStart>=_confirmationsBuffer){
               timeSinceStart -=_confirmationsBuffer;
           } else {timeSinceStart=0;}
           
            if (timeSinceStart >= _totalVestingTime) {
                totalAmount += vestLog[i].amount; // Vesting completed
            } else {
                totalAmount += uint256(vestLog[i].amount * timeSinceStart / _totalVestingTime); // Vesting in progress
            }
            vBalance += vestLog[i].amount;
            }
        }

        uint256 x = uint256(tokenFromReflection(_rOwned[account])+totalAmount);
        uint256 y = uint256(vBalance);

        if (x>=y){return x-y;} return 0;
    }

    function removeVestingSchedule(address _address, uint256 _index) private {
        require(_index < vestingSchedules[_address].length, "Index out of bounds");
           vestingSchedules[_address][_index].amount=0;
           vestingSchedules[_address][_index].startTime=0;
    }

   function clearVestingEntries(address _address, uint _entriesToClear) public {     
            require(_address != _vestingpool,"iVest: Operation cannont be called on the vestingpool"); 
            uint16 index=0;
            uint16 removalCount = 0;
            for (index ; index < vestingSchedules[_address].length && removalCount <_entriesToClear; index++) {
                if (block.timestamp > (vestingSchedules[_address][index].startTime)+(_totalVestingTime)){
                    removeVestingSchedule(_address,index);
                    removalCount++;
                }
            }

            if (removalCount>0){emit ClearedVestingEntry(_address,removalCount);}
            
            emptyVestingEntries(_address);
    }

    function emptyVestingEntries(address _address) private {      
        while (vestingSchedules[_address].length > 0) {
            uint256 lastIndex = vestingSchedules[_address].length - 1;
            if (vestingSchedules[_address][lastIndex].amount == 0 && vestingSchedules[_address][lastIndex].startTime == 0) {
                vestingSchedules[_address].pop();
            } else {
                break; 
            }
        }
    }

    function totalFees() public view returns (uint256,uint256,uint256,uint256) {
        return (_tFeeTotal[0],_tFeeTotal[1],_tFeeTotal[2],_tFeeTotal[3]);//[0.Vesting,1.Liquidity,2.DAO,3.BURN]
    }

    function tokenFromReflection(uint256 rAmount) private view returns(uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate =  _getRate();
        return rAmount/(currentRate);
    }

    function excludeFromReward(address account) public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        require(!_isExcluded[account], "Account is already excluded");
        if(_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeInReward(address account) external{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        require(_isExcluded[account], "Account is already excluded");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }
    
    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity,uint256 tBurn) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender]-(tAmount);
        _rOwned[sender] = _rOwned[sender]-(rAmount);
        _tOwned[recipient] = _tOwned[recipient]+(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient]+(rTransferAmount);        

        __burnFee(tBurn);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);

        emit Transfer(sender, recipient, tTransferAmount);
    }
    
    function excludeFromFee(address account) public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        _isExcludedFromFee[account] = true;
    }
    
    function includeInFee(address account) public {
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        _isExcludedFromFee[account] = false;
    }
    
    function __SetTaxes(uint256 newFee,uint8 mode)public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
            require(newFee<=10);
            require(newFee>=0);

            //MODE 1: Set Vesting Fee
            if (mode==1){_taxFee = newFee;_previousTaxFee=newFee;}
            //MODE 2: Set DAO Fee
            if (mode==2){_daoFee = newFee;_previousDaoFee=newFee;}
            //MODE 3: Set Liquidity Fee
            if (mode==3){_liquidityFee = newFee;_previousLiquidityFee=newFee;}
            //MODE 4: Set Burn Fee
            if (mode==4){_burnFee = newFee;_previousBurnFee=newFee;}
    }


    function __MasterSetter(uint256 newAmount,uint8 mode)public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        if (mode==1){_maxVestingEntries = newAmount;}    //Default is 30
        if (mode==2){_vestingEntriesToClear= newAmount;} //Default is 30
        if (mode==3){iVestMessengerFee = newAmount;}     //Default is 100000
        if (mode==4){_minPurchaseAmount = newAmount;}    //Default is 1000000
        if (mode==5){_WhaleThreshold = newAmount;}       //Default is 100000000000
        if (mode==6){_standardTipAmount = newAmount;}    //Default is 100000
        if (mode==7){_standardLikeAmount = newAmount;}   //Default is 10
        if (mode==8){_maxTxAmount = newAmount;}          //Default is 100000000000
    }

    function __SetTransferFee(uint256 newFee)public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
            require(newFee<=10);
            _transferFee = newFee;       
    }

    function setAdminAccount(address newAdmin) external{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        admin = newAdmin;
    }


    function setWhaleDonation(uint256 amount) external{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
        _whaleDonationFee = (amount);
    }
    
    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal-(rFee);
        _tFeeTotal[0] += (tFee); //[0.Vesting,1.Liquidity,2.DAO,3.BURN]
        if (tFee>0){emit Transfer(msg.sender, _vestingpool, tFee);} 
    }

    function __burnFee(uint256 tBurn) private {
        uint256 currentRate =  _getRate();
        uint256 rBurn = tBurn*(currentRate);

        _rTotal = _rTotal-(rBurn);
        _tTotal = _tTotal-(tBurn);
        _tFeeTotal[3] +=(tBurn); //[0.Vesting,1.Liquidity,2.DAO,3.BURN]
        if (tBurn>0){emit Transfer(msg.sender, address(0), tBurn);} 
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256,uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tBurn) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, tFee, tLiquidity,tBurn, _getRate());
        return (rAmount, rTransferAmount, rFee, tTransferAmount, tFee, tLiquidity,tBurn);
    }
    
    function _getTValues(uint256 tAmount) private view returns (uint256, uint256, uint256,uint256) {
        uint256 tFee = uint256(calcTaxFee(tAmount));
        uint256 tLiquidity = uint256(calcLiquidityFee(tAmount));
        uint256 tBurn = (calcBurnFee(tAmount));
        uint256 tTransferAmount = tAmount-(tFee)-(tLiquidity)-(tBurn);
        return (tTransferAmount, tFee, tLiquidity, tBurn);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tLiquidity,uint256 tBurn, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount*(currentRate);
        uint256 rFee = tFee*(currentRate);
        uint256 rLiquidity = tLiquidity*(currentRate);
        uint256 rBurn = tBurn*(currentRate);
        uint256 rTransferAmount = rAmount-(rFee)-(rLiquidity)-(rBurn);
        return (rAmount, rTransferAmount, rFee);
    }

    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply/(tSupply);
    }

    function _getCurrentSupply() private view returns(uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;      
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply-(_rOwned[_excluded[i]]);
            tSupply = tSupply-(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal/(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
    
    function _takeLiquidity(uint256 tLiquidity) private {
        uint256 currentRate =  _getRate();
        uint256 sumFees = _liquidityFee+_daoFee;
        if (sumFees < 2) {sumFees=2;} //ensure no div0 when fees are low

        uint256 lockLiquidity =(_liquidityFee*tLiquidity)/sumFees;
        uint256 DAOLiquidity = tLiquidity-lockLiquidity; 

        uint256 rLiquidity = lockLiquidity*(currentRate);
        _rOwned[LiquidityShield] = _rOwned[LiquidityShield]+(rLiquidity);
        if(_isExcluded[LiquidityShield])
        {_tOwned[LiquidityShield] = _tOwned[(LiquidityShield)]+(lockLiquidity);}
        
        uint256 rDAO = DAOLiquidity*(currentRate);
        _rOwned[DAOwallet] = _rOwned[DAOwallet]+(rDAO);        
        if(_isExcluded[DAOwallet])
        { _tOwned[DAOwallet] = _tOwned[DAOwallet]+(DAOLiquidity);}

        //update high level fee counters.
        _tFeeTotal[1]+=lockLiquidity; //[0.Vesting,1.Liquidity,2.DAO,3.BURN]
        _tFeeTotal[2]+=DAOLiquidity; //[0.Vesting,1.Liquidity,2.DAO,3.BURN]
    
        //Emit transfer here
        if (lockLiquidity>0){emit Transfer(msg.sender, LiquidityShield, lockLiquidity);}
        if (DAOLiquidity>0){emit Transfer(msg.sender, DAOwallet, DAOLiquidity);}
        
    }

    function calcTaxFee(uint256 _amount) private view returns (uint256) {
        return _amount*(_taxFee)/(100);
    }

    function calcLiquidityFee(uint256 _amount) private view returns (uint256) {
        return _amount*(_liquidityFee+_daoFee)/(100);
    }

    function calcBurnFee(uint256 _amount) private view returns (uint256) {
        return _amount*(_burnFee)/(100);
    }
    
    function removeAllFee() private {       
        _previousTaxFee = _taxFee;
        _previousLiquidityFee = _liquidityFee;
        _previousDaoFee = _daoFee;
        _previousBurnFee = _burnFee;
        
        _taxFee = 0;
        _liquidityFee = 0;
        _daoFee = 0;
        _burnFee=0;
    }
    

    function restoreAllFee() private {
        _taxFee = _previousTaxFee;
        _liquidityFee = _previousLiquidityFee;
        _daoFee = _previousDaoFee;
        _burnFee = _previousBurnFee;
    }
    
    function isExcludedFromFee(address account) public view returns(bool) {
        return _isExcludedFromFee[account];
    }

    function _transfer  (
        address from,
        address to,
        uint256 amount
    ) internal override  {
        require(from != address(0), "ERC20: transfer from the zero address");

        require(amount >= 10000, "iVest: Transfer amount must be at least 1 iVest (or 10000 including decimals)");   

        require(_MASTER_TRANSFERS_ENABLED, "iVest: Transfers are halted temporarily: _MASTER_TRANSFERS_ENABLED is DISABLED");
   
        //Transfers directly to the vestingpool will be considered a vesting reward donation
        if (to == _vestingpool){
            __MakeDonation(from,amount,1);
        }

        //Transfers directly to the burn address will be considered a Burn donation
        if (to == address(0)){
            __MakeDonation(from,amount,3);
        }
        

        //Prevent ordinary wallets from sending tokens spuriously...
        if(!_isExcludedFromFee[from]){
            require(to != owner, "iVest: This wallet cannont accept iVest from ordinary wallets.");
            require(to != address(this), "iVest: This wallet cannont accept iVest from ordinary wallets.");

            //If an ordinary wallet transfers to the DAO, award them karma and take no fee.
            if (to == DAOwallet){
                uint256 kAmount = amount/10000; 
                _tokenTransfer(from,to,amount,false);
                karma[from]+=kAmount; //Increases karma of the donating account equal to the tokens donated.
                emit AwardKarma(from, kAmount); //Emit an event               
                emit NewDonation (from, "DAO Donation", kAmount);
            }
        }

        //indicates if fee should be deducted from transfer
        bool takeFee = true;
        
        //if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFee[from] || _isExcludedFromFee[to]){
            takeFee = false;
        }
        
        //IS A SELL FROM A REGULAR WALLET
        if((to==_liquiditypool) &&!_isExcludedFromFee[from]){
        //check for whale
           if (tokenFromReflection(_rOwned[from])>=_WhaleThreshold){
                uint256 whaleFee =(amount*(_whaleDonationFee)/(100));
               __MakeDonation(from,whaleFee,4);
            }
        }            

        //IS A BUY FROM A REGULAR WALLET
        if(from==_liquiditypool){
            bool isWhale=false;
            if (tokenFromReflection(_rOwned[to])>=_WhaleThreshold){
                    isWhale=true;
            }

            if (_isExcludedFromFee[to]){
                    isWhale=false;
                    takeFee = false; 
                    removeAllFee();
            }
            
            if (to==LiquidityShield && address(msg.sender)==LiquidityShield ){
                takeFee = false;
                isWhale=false;
                removeAllFee();
            }


            _transferFromLP(from,to,amount,isWhale);
            if(!takeFee){restoreAllFee();}
            return;
        }

        //not exculded and sending tokens to the LP is a sell
        if(!_isExcludedFromFee[from] && to==_liquiditypool){
            takeFee = true;
        }
        
        //transfer amount, it will take tax, burn, liquidity fee
        _tokenTransfer(from,to,amount,takeFee);

    }
 
    
    function TOGGLE_MASTER_TRANSFERS(bool toggle)public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
       _MASTER_TRANSFERS_ENABLED = toggle;
    }

    function TOGGLE_MASTER__WALLETSCANTRADE(bool toggle)public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet, "iVest: Operation for owner/DAO only");
       _MASTER_WALLETSCANTRADE_FLAG = toggle;
    }

    function Karma_Award(address wallet, uint256 amount)public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet|| (address(msg.sender)==admin) , "iVest: Operation for owner/DAO only");
        karma[wallet] += amount;
        emit AwardKarma(wallet, amount);
    }

    function Karma_Spend(address wallet, uint256 amount)public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet||address(msg.sender)==wallet|| (address(msg.sender)==admin) , "iVest: Operation for wallet,owner/DAO only");
        karma[wallet] -= amount;
        emit SpendKarma(wallet, amount);
    }    

    function Karma_Transfer(address receiver, uint256 amount)public{
       require(karma[address(msg.sender)]>=amount, "iVest: Sender must have at least as much Karma as they are trying to send.");
       require(amount >= 1);
        
        karma[address(msg.sender)] -= amount;
        karma[receiver] += amount;

        emit TransferKarma(address(msg.sender), receiver, amount);
    } 
    
     function SyncLiquidityPool()public{
        require(address(msg.sender)==owner||address(msg.sender)==DAOwallet||address(msg.sender)==LiquidityShield|| (address(msg.sender)==admin) );
        IUniswapV2Pair(_liquiditypool).sync();
    }

    function _tokenTransfer(address sender, address recipient, uint256 amount,bool takeFee) private {
        //this method is responsible for taking all fee, if takeFee is true
        require(balanceOf(sender)>=amount, "Address: insufficient balance");

        if(!takeFee)
            removeAllFee();
        
        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferStandard(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            _transferStandard(sender, recipient, amount);
        }
        
        if(!takeFee)
            restoreAllFee();
    }

    function MakeDonation(uint256 tAmount,uint8 mode)public {
       __MakeDonation(address(msg.sender),tAmount,mode);
    }

    function __MakeDonation(address donor, uint256 tAmount,uint8 mode)private{ 
            require (tAmount >= 10000, "iVest: Minimum donation/transaction is 1 iVest. Account for 4 decimals");
            string memory donationType;
            
            //WhaleDonation
            if (mode==4){
                
                if (!takeWhaleDonations){return;}
                
                uint256 amountA = tAmount/2;
                uint256 amountB = tAmount - amountA;

                _transferVestingDonation(donor, _vestingpool, amountA);donationType="Whale - Vesting Donation";              
                _transferBURNDonation(donor, amountB);donationType="Whale - Burn Donation";

                tAmount /= 10000; //convert 1 iVest to 1 karma, where 1 iVest = 1.0000
                karma[donor]+=tAmount; 
                emit AwardKarma(donor, tAmount); 
                emit NewDonation (donor, donationType, tAmount);
                return;
            }

            donor = address(msg.sender);
            
            if (mode==1){_transferVestingDonation(donor, _vestingpool, tAmount);donationType="Vesting Donation";}
            if (mode==2){_transferLIQUIDITYDonation(donor, tAmount);donationType="Liquidity Donation";}
            if (mode==3){_transferBURNDonation(donor, tAmount);donationType="Burn Donation";}
                    
            //Award 1 karma for every 1 (10000/decimals) iVest tokens.
            tAmount /= 10000;
            karma[donor]+=tAmount; 
            emit AwardKarma(donor, tAmount); 
            emit NewDonation (donor, donationType, tAmount);
       }

    function _transferVestingDonation(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tFee) = _getValuesVesting(tAmount);
            _rOwned[sender] = _rOwned[sender]-(rAmount);
            _rOwned[recipient] = _rOwned[recipient]+(rTransferAmount);

            //if Excluded, adjust tOwned, also
            if(_isExcluded[sender]){
                _tOwned[sender] = _tOwned[sender]-(tAmount);
            } 

            _reflectFee(rFee, tFee);
            emit Transfer(sender, recipient, tAmount);
    }

    function _transferBURNDonation(address sender,uint256 tAmount) private {
        uint256 currentRate =  _getRate();
        (uint256 rAmount, uint256 tBurn) = (tAmount*currentRate,tAmount);
            _rOwned[sender] = _rOwned[sender]-(rAmount);

            //if Excluded, adjust tOwned, also
            if(_isExcluded[sender]){
                _tOwned[sender] = _tOwned[sender]-(tAmount);
            } 
        
            __burnFee(tBurn);
            emit Transfer(sender, address(0x0000000000000000000000000000), tAmount);
    }

    function _transferLIQUIDITYDonation(address sender,uint256 tAmount) private {
            uint256 LPshare = tAmount/2;
            uint256 DAOshare= tAmount-LPshare;
            _tokenTransfer(sender,LiquidityShield,LPshare,false);
            _tokenTransfer(sender,DAOwallet,DAOshare,false);

            _tFeeTotal[1]+=LPshare; //[0.Vesting,1.Liquidity,2.DAO,3.BURN]
            _tFeeTotal[2]+=DAOshare; //[0.Vesting,1.Liquidity,2.DAO,3.BURN]
    }

    function _getValuesVesting(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256) {
        uint256 _tFee =tAmount*(100)/(100);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) = _getRValues(tAmount, _tFee, 0,0, _getRate());
        return (rAmount, rTransferAmount, rFee, _tFee);
    }

    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
       //0%-3% for Peer-Peer transfers.
        uint256 fee =_transferFee;

       if (walletRegistrationStatus[(msg.sender)] >= 1){
            fee /=2;
       }       

       uint256 xFerFee= (tAmount*(fee)/(100))/4;
       uint256 tFee= xFerFee; 
       uint256 tLiquidity =xFerFee+xFerFee; //LiquidityPool+DAO
       uint256 tBurn =xFerFee;
       uint256 tTransferAmount= tAmount - tFee -tLiquidity-tBurn;
       
       (uint256 rAmount, uint256 rTransferAmount, uint256 rFee)=_getRValues(tAmount,tFee,tLiquidity,tBurn,_getRate());

            _rOwned[sender] = _rOwned[sender]-(rAmount);
            _rOwned[recipient] = _rOwned[recipient]+(rTransferAmount);
            __burnFee(tBurn);
            _takeLiquidity(tLiquidity);
            _reflectFee(rFee, tFee);
            
            emit Transfer(sender, recipient, tTransferAmount);
            
    }

    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tBurn) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender]-(rAmount);
        _tOwned[recipient] = _tOwned[recipient]+(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient]+(rTransferAmount);           
        __burnFee(tBurn);
        _takeLiquidity(tLiquidity);
        _reflectFee(rFee, tFee);
        

        emit Transfer(sender, recipient, tTransferAmount);

        if (recipient == _liquiditypool){
           clearVestingEntries(sender,_vestingEntriesToClear);
        }
    }


    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tBurn) = _getValues(tAmount);
            _tOwned[sender] = _tOwned[sender]-(tAmount);
            _rOwned[sender] = _rOwned[sender]-(rAmount);
            _rOwned[recipient] = _rOwned[recipient]+(rTransferAmount);   
            __burnFee(tBurn);
            _takeLiquidity(tLiquidity);
            _reflectFee(rFee, tFee);
            
            emit Transfer(sender, recipient, tTransferAmount);
            
    }


    function _transferFromLP(address sender, address recipient, uint256 tAmount, bool isWhale) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity,uint256 tBurn) = _getValues(tAmount);
        
        if (!_isExcluded[address(msg.sender)]||!_isExcluded[recipient]){
            require(_MASTER_WALLETSCANTRADE_FLAG,"iVest: Trading is not enabled at this moment.");
        }

        if (!_isExcluded[recipient] && _MASTER_TRANSFERS_ENABLED==true){
            require(tAmount <= _maxTxAmount, "iVest: LP transfer amount exceeds the maxTxAmount: 10M tokens.");
            require(tAmount >= _minPurchaseAmount, "iVest: Purchase from the Liquidity Pool is too small. Try a larger order. Default is 100 tokens.");
        }

        clearVestingEntries(recipient,_vestingEntriesToClear); //clear any old entries
        if(vestingSchedules[recipient].length>_maxVestingEntries){
            //"If after clearing old entries we have more than max, cancel the order.");
               revert("iVest: Maximum concurent vesting entries has been reached. Default is 30. Please wait 24hrs for an entry to clear.");
        }


        //BUY TRANSACTION FROM LP->WALLET
            //remove tokens from LP
            _tOwned[sender] = _tOwned[sender]-(tAmount);
            _rOwned[sender] = _rOwned[sender]-(rAmount);

            _tOwned[recipient] = _tOwned[recipient]+(tTransferAmount);
            _rOwned[recipient] = _rOwned[recipient]+(rTransferAmount);

            //Split the Transferamount
            uint256 immediateRelease = (tTransferAmount)/2;
            //Create a new vesting entry
            addVestingSchedule(recipient, (immediateRelease), block.timestamp);
            emit NewVestingEntry (recipient,(immediateRelease),block.timestamp,(block.timestamp+_totalVestingTime));
            
            //Take fees
            __burnFee(tBurn);
            _takeLiquidity(tLiquidity);
            _reflectFee(rFee, tFee);
            
            //whaledonation
            if (isWhale){
                uint256 whaleFee = tAmount*(_whaleDonationFee)/(100);
               __MakeDonation(recipient,whaleFee,4);
            }

            emit Transfer(sender, recipient, tTransferAmount);
    }
}