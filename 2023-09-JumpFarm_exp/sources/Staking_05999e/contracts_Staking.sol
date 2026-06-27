/*
                                                             ,---,  
         ,---._                          ____  ,-.----.   ,`--.' |  
       .-- -.' \                       ,'  , `.\    /  \  |   :  :  
       |    |   :         ,--,      ,-+-,.' _ ||   :    \ '   '  ;  
       :    ;   |       ,'_ /|   ,-+-. ;   , |||   |  .\ :|   |  |  
       :        |  .--. |  | :  ,--.'|'   |  ;|.   :  |: |'   :  ;  
       |    :   :,'_ /| :  . | |   |  ,', |  ':|   |   \ :|   |  '  
       :         |  ' | |  . . |   | /  | |  |||   : .   /'   :  |  
       |    ;   ||  | ' |  | | '   | :  | :  |,;   | |`-' ;   |  ;  
   ___ l         :  | | :  ' ; ;   . |  ; |--' |   | ;    `---'. |  
 /    /\    J   :|  ; ' |  | ' |   : |  | ,    :   ' |     `--..`;  
/  ../  `..-    ,:  | : ;  ; | |   : '  |/     :   : :    .--,_     
\    \         ; '  :  `--'   \;   | |`-'      |   | :    |    |`.  
 \    \      ,'  :  ,      .-./|   ;/          `---'.|    `-- -`, ; 
  "---....--'     `--`----'    '---'             `---`      '---`"  
                                                                    

(Website) https://jump.farm
(Telegram) https://t.me/jumpportal
(Twitter) https://twitter.com/jumpfarm

*/

pragma solidity 0.8.19;

interface IDistributor {
    function distribute() external;

    function nextRewardAt(uint256 _rate) external view returns (uint256);

    function nextReward() external view returns (uint256);
}

pragma solidity ^0.8.0;

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
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

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

pragma solidity 0.8.19;

interface IsStakingProtocol is IERC20 {
    function rebase(uint256 amount_, uint epoch_) external returns (uint256);

    function circulatingSupply() external view returns (uint256);

    function gonsForBalance(uint amount) external view returns (uint);

    function balanceForGons(uint gons) external view returns (uint);

    function index() external view returns (uint);
}

// OpenZeppelin Contracts v4.4.1 (token/ERC20/extensions/IERC20Metadata.sol)

pragma solidity ^0.8.0;

/**
 * @dev Interface for the optional metadata functions from the ERC20 standard.
 *
 * _Available since v4.1._
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
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

// OpenZeppelin Contracts (last updated v4.9.0) (access/Ownable.sol)

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
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

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
        require(
            newOwner != address(0),
            "Ownable: new owner is the zero address"
        );
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

pragma solidity 0.8.19;

contract Staking is Ownable {
    /// EVENTS ///

    event DistributorSet(address distributor);

    /// DATA STRUCTURES ///

    struct Epoch {
        uint256 length; // in seconds
        uint256 number; // since inception
        uint256 end; // timestamp
        uint256 distribute; // amount
    }

    /// STATE VARIABLES ///

    /// @notice TOKEN address
    IERC20 public immutable TOKEN;
    /// @notice sTOKEN address
    IsStakingProtocol public immutable sTOKEN;

    /// @notice Current epoch details
    Epoch public epoch;

    /// @notice Distributor address
    IDistributor public distributor;

    /// CONSTRUCTOR ///

    /// @param _TOKEN                   Address of TOKEN
    /// @param _sTOKEN                  Address of sTOKEN
    /// @param _epochLength            Epoch length
    /// @param _secondsTillFirstEpoch  Seconds till first epoch starts
    constructor(
        address _TOKEN,
        address _sTOKEN,
        uint256 _epochLength,
        uint256 _secondsTillFirstEpoch
    ) {
        require(_TOKEN != address(0), "Zero address: TOKEN");
        TOKEN = IERC20(_TOKEN);
        require(_sTOKEN != address(0), "Zero address");
        sTOKEN = IsStakingProtocol(_sTOKEN);

        epoch = Epoch({
            length: _epochLength,
            number: 0,
            end: block.timestamp + _secondsTillFirstEpoch,
            distribute: 0
        });
    }

    /// MUTATIVE FUNCTIONS ///

    /// @notice stake TOKEN
    /// @param _to address
    /// @param _amount uint
    function stake(address _to, uint256 _amount) external {
        rebase();
        TOKEN.transferFrom(msg.sender, address(this), _amount);
        sTOKEN.transfer(_to, _amount);
    }

    /// @notice redeem sTOKEN for TOKEN
    /// @param _to address
    /// @param _amount uint
    function unstake(address _to, uint256 _amount, bool _rebase) external {
        if (_rebase) rebase();
        sTOKEN.transferFrom(msg.sender, address(this), _amount);
        require(
            _amount <= TOKEN.balanceOf(address(this)),
            "Insufficient TOKEN balance in contract"
        );
        TOKEN.transfer(_to, _amount);
    }

    ///@notice Trigger rebase if epoch over
    function rebase() public {
        if (epoch.end <= block.timestamp) {
            sTOKEN.rebase(epoch.distribute, epoch.number);

            epoch.end = epoch.end + epoch.length;
            epoch.number++;

            if (address(distributor) != address(0)) {
                distributor.distribute();
            }

            uint256 balance = TOKEN.balanceOf(address(this));
            uint256 staked = sTOKEN.circulatingSupply();

            if (balance <= staked) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance - staked;
            }
        }
    }

    /// INTERNAL FUNCTIONS ///

    /// @notice         Send sTOKEN upon staking
    /// @param _to      Address of where sending sTOKEN
    /// @param _amount  Amount of sTOKEN to send
    /// @return _sent   Amount of sTOKEN sent
    function _send(
        address _to,
        uint256 _amount
    ) internal returns (uint256 _sent) {
        sTOKEN.transfer(_to, _amount); // send as sTOKEN (equal unit as TOKEN)
        return _amount;
    }

    /// VIEW FUNCTIONS ///

    /// @notice         Returns the sTOKEN index, which tracks rebase growth
    /// @return index_  Index of sTOKEN
    function index() public view returns (uint256 index_) {
        return sTOKEN.index();
    }

    /// @notice           Returns econds until the next epoch begins
    /// @return seconds_  Till next epoch
    function secondsToNextEpoch() external view returns (uint256 seconds_) {
        return epoch.end - block.timestamp;
    }

    /// MANAGERIAL FUNCTIONS ///

    /// @notice              Sets the contract address for LP staking
    /// @param _distributor  Distributor Address
    function setDistributor(address _distributor) external onlyOwner {
        distributor = IDistributor(_distributor);
        emit DistributorSet(_distributor);
    }
}
