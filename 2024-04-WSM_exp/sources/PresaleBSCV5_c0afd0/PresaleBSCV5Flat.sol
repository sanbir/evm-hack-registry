// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.7.0) (utils/Address.sol)

pragma solidity ^0.8.1;

/**
 * @dev Collection of functions related to the address type
 */
library AddressUpgradeable {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     * ====
     *
     * [IMPORTANT]
     * ====
     * You shouldn't rely on `isContract` to protect against flash loan attacks!
     *
     * Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
     * like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
     * constructor.
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://diligence.consensys.net/posts/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.5.11/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCall(target, data, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        require(isContract(target), "Address: call to non-contract");

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        require(isContract(target), "Address: static call to non-contract");

        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResult(success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verifies that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly
                /// @solidity memory-safe-assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }
}


// File @openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol@v4.7.3

// OpenZeppelin Contracts (last updated v4.7.0) (proxy/utils/Initializable.sol)

pragma solidity ^0.8.2;

/**
 * @dev This is a base contract to aid in writing upgradeable contracts, or any kind of contract that will be deployed
 * behind a proxy. Since proxied contracts do not make use of a constructor, it's common to move constructor logic to an
 * external initializer function, usually called `initialize`. It then becomes necessary to protect this initializer
 * function so it can only be called once. The {initializer} modifier provided by this contract will have this effect.
 *
 * The initialization functions use a version number. Once a version number is used, it is consumed and cannot be
 * reused. This mechanism prevents re-execution of each "step" but allows the creation of new initialization steps in
 * case an upgrade adds a module that needs to be initialized.
 *
 * For example:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * contract MyToken is ERC20Upgradeable {
 *     function initialize() initializer public {
 *         __ERC20_init("MyToken", "MTK");
 *     }
 * }
 * contract MyTokenV2 is MyToken, ERC20PermitUpgradeable {
 *     function initializeV2() reinitializer(2) public {
 *         __ERC20Permit_init("MyToken");
 *     }
 * }
 * ```
 *
 * TIP: To avoid leaving the proxy in an uninitialized state, the initializer function should be called as early as
 * possible by providing the encoded function call as the `_data` argument to {ERC1967Proxy-constructor}.
 *
 * CAUTION: When used with inheritance, manual care must be taken to not invoke a parent initializer twice, or to ensure
 * that all initializers are idempotent. This is not verified automatically as constructors are by Solidity.
 *
 * [CAUTION]
 * ====
 * Avoid leaving a contract uninitialized.
 *
 * An uninitialized contract can be taken over by an attacker. This applies to both a proxy and its implementation
 * contract, which may impact the proxy. To prevent the implementation contract from being used, you should invoke
 * the {_disableInitializers} function in the constructor to automatically lock it when it is deployed:
 *
 * [.hljs-theme-light.nopadding]
 * ```
 * /// @custom:oz-upgrades-unsafe-allow constructor
 * constructor() {
 *     _disableInitializers();
 * }
 * ```
 * ====
 */
abstract contract Initializable {
    /**
     * @dev Indicates that the contract has been initialized.
     * @custom:oz-retyped-from bool
     */
    uint8 private _initialized;

    /**
     * @dev Indicates that the contract is in the process of being initialized.
     */
    bool private _initializing;

    /**
     * @dev Triggered when the contract has been initialized or reinitialized.
     */
    event Initialized(uint8 version);

    /**
     * @dev A modifier that defines a protected initializer function that can be invoked at most once. In its scope,
     * `onlyInitializing` functions can be used to initialize parent contracts. Equivalent to `reinitializer(1)`.
     */
    modifier initializer() {
        bool isTopLevelCall = !_initializing;
        require(
            (isTopLevelCall && _initialized < 1) || (!AddressUpgradeable.isContract(address(this)) && _initialized == 1),
            "Initializable: contract is already initialized"
        );
        _initialized = 1;
        if (isTopLevelCall) {
            _initializing = true;
        }
        _;
        if (isTopLevelCall) {
            _initializing = false;
            emit Initialized(1);
        }
    }

    /**
     * @dev A modifier that defines a protected reinitializer function that can be invoked at most once, and only if the
     * contract hasn't been initialized to a greater version before. In its scope, `onlyInitializing` functions can be
     * used to initialize parent contracts.
     *
     * `initializer` is equivalent to `reinitializer(1)`, so a reinitializer may be used after the original
     * initialization step. This is essential to configure modules that are added through upgrades and that require
     * initialization.
     *
     * Note that versions can jump in increments greater than 1; this implies that if multiple reinitializers coexist in
     * a contract, executing them in the right order is up to the developer or operator.
     */
    modifier reinitializer(uint8 version) {
        require(!_initializing && _initialized < version, "Initializable: contract is already initialized");
        _initialized = version;
        _initializing = true;
        _;
        _initializing = false;
        emit Initialized(version);
    }

    /**
     * @dev Modifier to protect an initialization function so that it can only be invoked by functions with the
     * {initializer} and {reinitializer} modifiers, directly or indirectly.
     */
    modifier onlyInitializing() {
        require(_initializing, "Initializable: contract is not initializing");
        _;
    }

    /**
     * @dev Locks the contract, preventing any future reinitialization. This cannot be part of an initializer call.
     * Calling this in the constructor of a contract will prevent that contract from being initialized or reinitialized
     * to any version. It is recommended to use this to lock implementation contracts that are designed to be called
     * through proxies.
     */
    function _disableInitializers() internal virtual {
        require(!_initializing, "Initializable: contract is initializing");
        if (_initialized < type(uint8).max) {
            _initialized = type(uint8).max;
            emit Initialized(type(uint8).max);
        }
    }
}


// File @openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol@v4.7.3

// OpenZeppelin Contracts v4.4.1 (utils/Context.sol)

pragma solidity ^0.8.0;

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
abstract contract ContextUpgradeable is Initializable {
    function __Context_init() internal onlyInitializing {
    }

    function __Context_init_unchained() internal onlyInitializing {
    }
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}


// File @openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol@v4.7.3

// OpenZeppelin Contracts (last updated v4.7.0) (security/Pausable.sol)

pragma solidity ^0.8.0;


/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract PausableUpgradeable is Initializable, ContextUpgradeable {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    function __Pausable_init() internal onlyInitializing {
        __Pausable_init_unchained();
    }

    function __Pausable_init_unchained() internal onlyInitializing {
        _paused = false;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        _requireNotPaused();
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        _requirePaused();
        _;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Throws if the contract is paused.
     */
    function _requireNotPaused() internal view virtual {
        require(!paused(), "Pausable: paused");
    }

    /**
     * @dev Throws if the contract is not paused.
     */
    function _requirePaused() internal view virtual {
        require(paused(), "Pausable: not paused");
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}


// File @openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol@v4.7.3

// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20Upgradeable {
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
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}


// File @openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol@v4.7.3

// OpenZeppelin Contracts v4.4.1 (security/ReentrancyGuard.sol)

pragma solidity ^0.8.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuardUpgradeable is Initializable {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    function __ReentrancyGuard_init() internal onlyInitializing {
        __ReentrancyGuard_init_unchained();
    }

    function __ReentrancyGuard_init_unchained() internal onlyInitializing {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}


// File @openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol@v4.7.3

// OpenZeppelin Contracts (last updated v4.7.0) (access/Ownable.sol)

pragma solidity ^0.8.0;


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
abstract contract OwnableUpgradeable is Initializable, ContextUpgradeable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    function __Ownable_init() internal onlyInitializing {
        __Ownable_init_unchained();
    }

    function __Ownable_init_unchained() internal onlyInitializing {
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

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}



pragma solidity 0.8.9;
interface Aggregator {
  function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface StakingManager {
  function depositByPresale(address _user, uint256 _amount) external;
}

interface IQuoter {
  function quoteExactInput(bytes memory path, uint256 amountIn) external returns (uint256 amountOut);

  function quoteExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96) external returns (uint256 amountOut);

  function quoteExactOutput(bytes memory path, uint256 amountOut) external returns (uint256 amountIn);

  function quoteExactOutputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountOut, uint160 sqrtPriceLimitX96) external view returns (uint256 amountIn);
}

contract PresaleBSCV5 is Initializable, ReentrancyGuardUpgradeable, OwnableUpgradeable, PausableUpgradeable {
  uint256 public totalTokensSold;
  uint256 public startTime;
  uint256 public endTime;
  uint256 public claimStart;
  address public saleToken;
  uint256 public baseDecimals;
  uint256 public maxTokensToBuy;
  uint256 public currentStep;
  uint256[][3] public rounds;
  uint256 public checkPoint;
  uint256 public usdRaised;
  uint256[] public prevCheckpoints;
  uint256[] public remainingTokensTracker;
  uint256 public timeConstant;
  address public paymentWallet;
  bool public dynamicTimeFlag;
  bool public whitelistClaimOnly;

  IERC20Upgradeable public USDTInterface;
  Aggregator public aggregatorInterface;
  mapping(address => uint256) public userDeposits;
  mapping(address => bool) public hasClaimed;
  mapping(address => bool) public isBlacklisted;
  mapping(address => bool) public isWhitelisted;
  address public admin;

  StakingManager public stakingManagerInterface;
  bool public stakeingWhitelistStatus;
  uint256 public totalBoughtAndStaked;

  uint256 public directTotalTokensSold;
  uint256 public directUsdPrice;
  bool public dynamicSaleState;
  uint256 public percent;
  uint256 public maxTokensToSell;
  IQuoter public quoter;
  address public seeder;
  bool public seederLocked;
  bool public isClaimLive;
  uint256 public newUserDepositsCount;
  mapping(address => uint256) public newUserDeposits;

  event SaleTimeSet(uint256 _start, uint256 _end, uint256 timestamp);
  event SaleTimeUpdated(bytes32 indexed key, uint256 prevValue, uint256 newValue, uint256 timestamp);
  event TokensBought(address indexed user, uint256 indexed tokensBought, address indexed purchaseToken, uint256 amountPaid, uint256 usdEq, uint256 timestamp);
  event TokensAdded(address indexed token, uint256 noOfTokens, uint256 timestamp);
  event TokensClaimed(address indexed user, uint256 amount, uint256 timestamp);
  event ClaimStartUpdated(uint256 prevValue, uint256 newValue, uint256 timestamp);
  event MaxTokensUpdated(uint256 prevValue, uint256 newValue, uint256 timestamp);
  event TokensBoughtAndStaked(address indexed user, uint256 indexed tokensBought, address indexed purchaseToken, uint256 amountPaid, uint256 usdEq, uint256 timestamp);
  event TokensClaimedAndStaked(address indexed user, uint256 amount, uint256 timestamp);

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() initializer {}

  /**
   * @dev To pause the presale
   */
  function pause() external onlyOwner {
    _pause();
  }

  /**
   * @dev To unpause the presale
   */
  function unpause() external onlyOwner {
    _unpause();
  }

  /**
   * @dev To get latest BNB price in 10**18 format
   */
  function getLatestPrice() public view returns (uint256) {
    (, int256 price, , , ) = aggregatorInterface.latestRoundData();
    price = (price * (10 ** 10));
    return uint256(price);
  }

  function sendValue(address payable recipient, uint256 amount) internal {
    require(address(this).balance >= amount, 'Low balance');
    (bool success, ) = recipient.call{value: amount}('');
    require(success, 'BNB Payment failed');
  }

  /**
   * @dev To claim tokens after claiming starts
   */
  function claim() external whenNotPaused returns (bool) {
    require(isClaimLive, 'Claims Not Live Yet');
    require(saleToken != address(0), 'Sale token not added');
    require(!isBlacklisted[_msgSender()], 'This Address is Blacklisted');
    if (whitelistClaimOnly) {
      require(isWhitelisted[_msgSender()], 'User not whitelisted for claim');
    }
    require(block.timestamp >= claimStart, 'Claim has not started yet');
    require(!hasClaimed[_msgSender()], 'Already claimed');
    hasClaimed[_msgSender()] = true;
    uint256 amount = newUserDeposits[_msgSender()];
    require(amount > 0, 'Nothing to claim');
    delete newUserDeposits[_msgSender()];
    bool success = IERC20Upgradeable(saleToken).transfer(_msgSender(), amount);
    require(success, 'Token transfer failed');
    emit TokensClaimed(_msgSender(), amount, block.timestamp);
    return true;
  }

  function claimAndStake() external whenNotPaused returns (bool) {
    require(saleToken != address(0), 'Sale token not added');
    require(!isBlacklisted[_msgSender()], 'This Address is Blacklisted');
    if (stakeingWhitelistStatus) {
      require(isWhitelisted[_msgSender()], 'User not whitelisted for stake');
    }
    uint256 amount = newUserDeposits[_msgSender()];
    require(amount > 0, 'Nothing to stake');
    stakingManagerInterface.depositByPresale(_msgSender(), amount);
    delete newUserDeposits[_msgSender()];
    emit TokensClaimedAndStaked(_msgSender(), amount, block.timestamp);
    return true;
  }

  function setDynamicSaleState(bool state) external onlyOwner {
    dynamicSaleState = state;
  }

  function fetchPrice(uint256 amountOut) public returns (uint256) {
    bytes memory data = abi.encodeWithSelector(quoter.quoteExactOutputSingle.selector, 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c, 0x62694D43Ccb9B64e76e38385d15e325c7712A735, 3000, amountOut, 0);
    (bool success, bytes memory result) = address(quoter).call(data);
    require(success, 'Call to Quoter failed');
    uint256 amountIn = abi.decode(result, (uint256));
    return amountIn + ((amountIn * percent) / 100);
  }

  function setPercent(uint256 _percent) external onlyOwner {
    percent = _percent;
  }

  function setMaxTokensToSell(uint256 _maxTokensToSell) external onlyOwner {
    maxTokensToSell = _maxTokensToSell;
  }

  function buyWithBNB(uint256 amount, bool _stakeStaus) external payable whenNotPaused nonReentrant returns (bool) {
    require(dynamicSaleState, 'dynamic sale not active');
    require(amount <= maxTokensToSell - directTotalTokensSold, 'amount exceeds max tokens to be sold');
    directTotalTokensSold += amount;
    uint256 ethAmount = fetchPrice(amount * baseDecimals);
    require(msg.value >= ethAmount, 'Less payment');
    uint256 excess = msg.value - ethAmount;
    sendValue(payable(paymentWallet), ethAmount);
    if (excess > 0) sendValue(payable(_msgSender()), excess);
    if (!_stakeStaus) {
      bool success = IERC20Upgradeable(saleToken).transfer(_msgSender(), (amount * baseDecimals));
      require(success, 'Token transfer failed');
      emit TokensBought(_msgSender(), amount, address(0), ethAmount, 0, block.timestamp);
    } else {
      stakingManagerInterface.depositByPresale(_msgSender(), amount * baseDecimals);
      emit TokensBoughtAndStaked(_msgSender(), amount, address(0), ethAmount, 0, block.timestamp);
    }

    return true;
  }

  function buyWithUSDT(uint256 amount, bool _stakeStaus) external whenNotPaused returns (bool) {
    require(dynamicSaleState, 'dynamic sale not active');
    require(amount <= maxTokensToSell - directTotalTokensSold, 'amount exceeds max tokens to be sold');
    directTotalTokensSold += amount;
    uint256 ethAmount = fetchPrice(amount * baseDecimals);
    uint256 usdPrice = (ethAmount * getLatestPrice()) / baseDecimals;
    (bool success, ) = address(USDTInterface).call(abi.encodeWithSignature('transferFrom(address,address,uint256)', _msgSender(), paymentWallet, usdPrice));
    require(success, 'Token payment failed');
    if (!_stakeStaus) {
      bool transferSuccess = IERC20Upgradeable(saleToken).transfer(_msgSender(), (amount * baseDecimals));
      require(transferSuccess, 'Token transfer failed');
      emit TokensBought(_msgSender(), amount, address(USDTInterface), usdPrice, usdPrice, block.timestamp);
    } else {
      stakingManagerInterface.depositByPresale(_msgSender(), amount * baseDecimals);
      emit TokensBoughtAndStaked(_msgSender(), amount, address(0), ethAmount, 0, block.timestamp);
    }

    return true;
  }

  function changeMaxTokensToBuy(uint256 _maxTokensToBuy) external onlyOwner {
    require(_maxTokensToBuy > 0, 'Zero max tokens to buy value');
    uint256 prevValue = maxTokensToBuy;
    maxTokensToBuy = _maxTokensToBuy;
    emit MaxTokensUpdated(prevValue, _maxTokensToBuy, block.timestamp);
  }

  function changeRoundsData(uint256[][3] memory _rounds) external onlyOwner {
    rounds = _rounds;
  }

  /**
   * @dev To add users to blacklist which restricts blacklisted users from claiming
   * @param _usersToBlacklist addresses of the users
   */
  function blacklistUsers(address[] calldata _usersToBlacklist) external onlyOwner {
    for (uint256 i = 0; i < _usersToBlacklist.length; i++) {
      isBlacklisted[_usersToBlacklist[i]] = true;
    }
  }

  /**
   * @dev To remove users from blacklist which restricts blacklisted users from claiming
   * @param _userToRemoveFromBlacklist addresses of the users
   */
  function removeFromBlacklist(address[] calldata _userToRemoveFromBlacklist) external onlyOwner {
    for (uint256 i = 0; i < _userToRemoveFromBlacklist.length; i++) {
      isBlacklisted[_userToRemoveFromBlacklist[i]] = false;
    }
  }

  /**
   * @dev To add users to whitelist which restricts users from claiming if claimWhitelistStatus is true
   * @param _usersToWhitelist addresses of the users
   */
  function whitelistUsers(address[] calldata _usersToWhitelist) external onlyOwner {
    for (uint256 i = 0; i < _usersToWhitelist.length; i++) {
      isWhitelisted[_usersToWhitelist[i]] = true;
    }
  }

  /**
   * @dev To remove users from whitelist which restricts users from claiming if claimWhitelistStatus is true
   * @param _userToRemoveFromWhitelist addresses of the users
   */
  function removeFromWhitelist(address[] calldata _userToRemoveFromWhitelist) external onlyOwner {
    for (uint256 i = 0; i < _userToRemoveFromWhitelist.length; i++) {
      isWhitelisted[_userToRemoveFromWhitelist[i]] = false;
    }
  }

  /**
   * @dev To set status for claim whitelisting
   * @param _status bool value
   */
  function setClaimWhitelistStatus(bool _status) external onlyOwner {
    whitelistClaimOnly = _status;
  }

  /**
   * @dev To set payment wallet address
   * @param _newPaymentWallet new payment wallet address
   */
  function changePaymentWallet(address _newPaymentWallet) external onlyOwner {
    require(_newPaymentWallet != address(0), 'address cannot be zero');
    paymentWallet = _newPaymentWallet;
  }

  /**
   * @dev To manage time gap between two rounds
   */
  function manageTimeDiff() internal {
    for (uint256 i; i < rounds[2].length - currentStep; i++) {
      rounds[2][currentStep + i] = block.timestamp + i * timeConstant;
    }
  }

  /**
   * @dev To set time constant for manageTimeDiff()
   * @param _timeConstant time in <days>*24*60*60 format
   */
  function setTimeConstant(uint256 _timeConstant) external onlyOwner {
    timeConstant = _timeConstant;
  }

  /**
   * @dev To get array of round details at once
   * @param _no array index
   */
  function roundDetails(uint256 _no) external view returns (uint256[] memory) {
    return rounds[_no];
  }

  /**
   * @dev to update newUserDeposits for claims remaining on ETH
   * @param _users array of users
   * @param _newUserDeposits array of newUserDeposits associated with users
   */
  function newUserDepositeSeeder(address[] calldata _users, uint256[] calldata _newUserDeposits) external {
    require(!seederLocked, 'seederLocked');
    require(_msgSender() == seeder, 'Caller is not seeder');
    require(_users.length == _newUserDeposits.length, 'Length mismatch');
    for (uint256 i = 0; i < _users.length; i++) {
      newUserDeposits[_users[i]] = _newUserDeposits[i];
      newUserDepositsCount++;
    }
  }

  /**
   * @dev to initialize staking manager with new addredd
   * @param _stakingManagerAddress address of the staking smartcontract
   */
  function setStakingManager(address _stakingManagerAddress) external onlyOwner {
    require(_stakingManagerAddress != address(0), 'staking manager cannot be inatialized with zero address');
    stakingManagerInterface = StakingManager(_stakingManagerAddress);
    IERC20Upgradeable(saleToken).approve(_stakingManagerAddress, type(uint256).max);
  }

  /**
   * @dev     Function to set Sale token
   * @param   _saleToken  address of the sale token
   * @param   _quoter  address of quoter contract
   * @param   _dynamicSaleState  flag to set sale state
   * @param   _seeder  address of new seeder
   */
  function setSaleTokenQuoterSeeder(address _saleToken, address _quoter, bool _dynamicSaleState, address _seeder) external onlyOwner {
    require(_saleToken != address(0), 'zero address');
    require(_quoter != address(0), 'zero address');
    saleToken = _saleToken;
    quoter = IQuoter(_quoter);
    dynamicSaleState = _dynamicSaleState;
    seeder = _seeder;
  }

  /**
   * @dev     To update the seeder address
   * @param   _seeder  address of seeder
   */
  function setSeeder(address _seeder) external onlyOwner {
    require(_seeder != address(0), 'zero address');
    seeder = _seeder;
  }

  /**
   * @dev     To lock the seeder from updating more data
   */
  function renounceSeeder() external onlyOwner {
    seederLocked = true;
  }

  /**
   * @dev     To change claim status to allow claims
   */
  function setClaimLiveStatus(bool _status) external onlyOwner {
    isClaimLive = _status;
  }
}
