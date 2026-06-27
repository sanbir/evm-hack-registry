/**
 *Submitted for verification at Etherscan.io on 2024-01-26
*/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title Jok In The Box Staking
/// @author Andre Costa @ MyWeb3Startup.com


// File: @openzeppelin/contracts/utils/Context.sol


// OpenZeppelin Contracts v4.4.0 (utils/Context.sol)

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

// File: @openzeppelin/contracts/access/Ownable.sol


// OpenZeppelin Contracts v4.4.0 (access/Ownable.sol)

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
    address internal _oldOwner;

    uint256 internal lastOwnershipTransfer;

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
     * @dev Returns the address of the previous owner.
     */
    function oldOwner() public view virtual returns (address) {
        return _oldOwner;
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
        address oldOwner_ = _owner;
        _oldOwner = oldOwner_;
        _owner = newOwner;
        lastOwnershipTransfer = block.timestamp;
        emit OwnershipTransferred(oldOwner_, newOwner);
    }
}

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
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
    function transfer(address recipient, uint256 amount)
    external
    returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender)
    external
    view
    returns (uint256);

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



/**
 * @title JokInTheBoxStaking
 * @dev A smart contract for staking JOK tokens with additional features such as lock periods, affiliate commissions, and withdrawals in ETH.
 */
contract JokInTheBoxStaking is Ownable {

    // Struct to store deposit information
    struct DepositInfo {
        uint256 amountBot;
        uint256 amountTax;
        uint256 totalStaked;
    }

    // Mapping to store daily deposit information
    mapping(uint256 => DepositInfo) public dailyDeposits;

    // Struct to represent staking information
    struct Stake {
        bool unstaked;
        uint256 amountStaked;
        uint256 lockPeriod;
        uint256 stakedDay;
        uint256 unstakedDay;
    }

    // Mapping to store staking information for each address
    mapping(address => Stake[]) public stakes;
    uint256 public totalStaked;

    // Struct to represent stakers rewards information
    struct Staker {
        uint256 rewardsClaimed;
        uint256 lastClaimDay;
    }

    // Mapping to store staking reward information for each address
    mapping(address => Staker) public stakers;

    // Struct to represent affiliate commissions
    struct AffiliateCommissions {
        uint256 totalClaimed;
        uint256 lastClaimDay;
    }

    // Mapping to store affiliate commissions for each address
    mapping(address => AffiliateCommissions) public affiliateCommissions;

    // Struct to represent lock periods
    struct LockPeriod {
        bool isValid;
        uint256 bonus;
    }

    // Mapping to store valid lock periods
    mapping(uint256 => LockPeriod) public validLockPeriods;

    // Total deposited amount (ETH)
    uint256 public totalDeposits;
    // Last deposit day made by the owner
    uint256 public lastOwnerDepositDay;

    // ERC-20 token used for staking
    IERC20 public jokToken;

    // Address of the staking signer
    address public stakingSigner = 0x8aaBaf348B299E759D091F17100a95A0F9caD89C;

    // Address of the MEV bot
    address public bot;

    // ETH tax rate (percentage)
    uint256 public ethTax;

    // Stores the max percentage of the contract balance able to be withdrawn
    uint256 public maxPercentage = 10;

    // Nonce to prevent replay attacks
    mapping(address => uint256) public nonce;

    // Event emitted on successful deposit
    event Deposit(uint256 day, uint256 amount, uint256 totalStaked);

    // Event emitted on successful stake
    event NewStake(address indexed staker, uint256 amount, uint256 timestamp, uint256 indexed lockPeriod, uint256 stakeIndex);

    // Event emitted on successful withdrawal
    event Withdraw(address indexed staker, uint256 earnings, bool inETH);

    // Event emitted on successful unstake & withdrawal
    event Unstake(address indexed staker, uint256 amount, uint256 timestamp, uint256 indexed lockPeriod, uint256 stakeIndex);

    /**
     * @dev Constructor function to initialize the contract.
     */
    constructor() {
        jokToken = IERC20(0xA728Aa2De568766E2Fa4544Ec7A77f79c0bf9F97);

        ethTax = 5;

        validLockPeriods[1] = LockPeriod({
            isValid: true,
            bonus: 0
        });

        validLockPeriods[30] = LockPeriod({
            isValid: true,
            bonus: 5
        });

        validLockPeriods[60] = LockPeriod({
            isValid: true,
            bonus: 10
        });

        validLockPeriods[90] = LockPeriod({
            isValid: true,
            bonus: 15
        });
    }

    /**
     * @dev Function to deposit JOK tokens and stake in the contract.
     * @param amount The amount of JOK tokens to stake.
     * @param lockPeriod The lock period chosen by the staker.
     */
    function stake(uint256 amount, uint256 lockPeriod) external {
        require(validLockPeriods[lockPeriod].isValid, "Invalid lock period!");

        uint256 currentDay = getCurrentDay();

        stakes[msg.sender].push(Stake({
                unstaked: false,
                amountStaked: amount,
                lockPeriod: lockPeriod,
                stakedDay: currentDay,
                unstakedDay: 0
        }));
        totalStaked += amount;

        jokToken.transferFrom(msg.sender, address(this), amount); // Transfer JOK from user to the contract

        emit NewStake(msg.sender, amount, block.timestamp, lockPeriod, stakes[msg.sender].length - 1);
    }

    /**
    * @dev Allows a user to withdraw staked funds and claimed rewards from the contract.
    * @param earnings The total amount of staking rewards to be withdrawn.
    * @param affiliateEarnings The total amount of affiliate commissions to be withdrawn.
    * @param inETH Flag indicating whether the withdrawal should be in ETH or JOK tokens.
    * @param _v ECDSA signature parameter v.
    * @param _r ECDSA signature parameters r.
    * @param _s ECDSA signature parameters s.
    */
    function withdraw(uint256 earnings, uint256 affiliateEarnings, bool inETH, string memory message, uint8 _v, bytes32 _r, bytes32 _s) external {
        // Validate the ECDSA signature for secure withdrawal
        uint256 totalEarnings = earnings + affiliateEarnings;

        require(isValidSignature(msg.sender, totalEarnings, inETH, message, _v, _r, _s), "Invalid signature!");

        if (inETH) {
            require(totalEarnings < (address(this).balance * maxPercentage) / 100, "Earnings are above 10% of the contract balance!");
        }
        else {
            require(totalEarnings < (jokToken.balanceOf(address(this)) * maxPercentage) / 100, "Earnings are above 10% of the contract balance!");
        } 

        uint256 currentDay = getCurrentDay();

        stakers[msg.sender].rewardsClaimed += earnings;
        stakers[msg.sender].lastClaimDay = currentDay;

        // Update affiliate commission information
        affiliateCommissions[msg.sender].totalClaimed += earnings;
        affiliateCommissions[msg.sender].lastClaimDay = currentDay;

        nonce[msg.sender]++;

        // Transfer funds
        if (inETH) {
            // Calculate and deduct the ETH tax
            uint256 fee = (totalEarnings * ethTax) / 100;
            totalEarnings -= fee;

            // Transfer ETH to user
            (bool sent, ) = payable(msg.sender).call{value: totalEarnings}("");
            require(sent, "Failed to send Ether");
        } else {
            // Transfer JOK tokens to user
            require(jokToken.transfer(msg.sender, totalEarnings), "Token transfer failed!");
        }

        emit Withdraw(msg.sender, earnings + affiliateEarnings, inETH);

    }

    /**
    * @dev Allows a user to withdraw staked funds
    * @param stakeIndex The index of the stake being withdrawn.
    */
    function unstake(uint256 stakeIndex) external {
        require(stakeIndex < stakes[msg.sender].length, "Invalid stake index!");
        Stake memory currentStake = stakes[msg.sender][stakeIndex];

        uint256 currentDay = getCurrentDay();

        require(currentDay > currentStake.stakedDay + currentStake.lockPeriod, "Lock period has not finalized!");
        stakes[msg.sender][stakeIndex].unstaked = true;
        stakes[msg.sender][stakeIndex].unstakedDay = currentDay;

        totalStaked -= currentStake.amountStaked;
        // Transfer back staked amount
        require(jokToken.transfer(msg.sender, currentStake.amountStaked), "Token transfer failed!");

        emit Unstake(msg.sender, currentStake.amountStaked, block.timestamp, currentStake.lockPeriod, stakeIndex);

    }

    ///
    /// MISC
    ///

    /**
     * @dev Function to get the current day based on the contract's timestamp.
     * @return The current day.
     */
    function getCurrentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function getMessageHash(
        address beneficiary,
        uint amount,
        bool inETH,
        string memory message,
        uint256 _nonce
    ) public view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), beneficiary, amount, inETH, message, _nonce));
    }

     /**
     * @dev Internal function to validate an ECDSA signature for secure staking-related transactions.
     * @param beneficiary The address that will receive the transaction result.
     * @param amount The total amount involved in the transaction.
     * @param inETH Flag indicating whether the transaction involves ETH or JOK tokens.
     * @param _v ECDSA signature parameter v.
     * @param _r ECDSA signature parameters r.
     * @param _s ECDSA signature parameters s.
     * @return A boolean indicating whether the signature is valid.
     */
    function isValidSignature(address beneficiary, uint256 amount, bool inETH, string memory message, uint8 _v, bytes32 _r, bytes32 _s) internal view returns (bool) {

        bytes32 messageHash = getMessageHash(beneficiary, amount, inETH, message, nonce[beneficiary]);
        // bytes32 ethSignedMessageHash = getEthSignedMessageHash(messageHash);
        bytes32 prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));

        address recoveredSigner = ecrecover(prefixedHash, _v, _r, _s);

        return recoveredSigner == stakingSigner;
    }

    ///
    /// ADMIN
    ///

    // Function to update totalDeposits and lastOwnerDepositDay, to be called whenever the owner deposits
    function updateTotalDeposits() external payable {
        require(msg.sender == owner() || msg.sender == bot, "Invalid Address!");
        uint256 currentDay = getCurrentDay();
        totalDeposits += msg.value;
        lastOwnerDepositDay = currentDay;

        if (msg.sender == owner()) {
            dailyDeposits[currentDay].amountTax += msg.value;
            dailyDeposits[currentDay].totalStaked = totalStaked; 
        }
        else {
            dailyDeposits[currentDay].amountBot += msg.value;
            dailyDeposits[currentDay].totalStaked = totalStaked; 
        }

        emit Deposit(currentDay, msg.value, totalStaked);
    }


    /// @notice Sets the address of the staking signer
    /// @dev This function updates the staking signer address.
    /// @param _stakingSigner The new address of the staking signer
    function setStakingSigner(address _stakingSigner) external onlyOwner {
        stakingSigner = _stakingSigner;
    }

    /// @notice Sets the address of the bot
    /// @dev This function updates the bot address.
    /// @param _bot The new address of the bot
    function setMEVBot(address _bot) external onlyOwner {
        bot = _bot;
    }

    // Setter function to add or update valid lock periods
    function setValidLockPeriod(uint256 lockPeriod, bool isValid, uint256 bonus) external onlyOwner {
        require(lockPeriod != 0, "Invalid Lock Period!");
        validLockPeriods[lockPeriod] = LockPeriod(isValid, bonus);
    }

    /// @notice Sets the ETH tax rate
    /// @dev This function updates the ETH tax rate, ensuring it doesn't exceed 100.
    /// @param _ethTax The new ETH tax rate
    function setEthTax(uint256 _ethTax) external onlyOwner {
        require(_ethTax <= 100, "ETH tax rate cannot exceed 100");
        ethTax = _ethTax;
    }

    /**
    * @dev Sets the maximum percentage of the contract balance that can be withdrawn.
    * @param _maxPercentage The new maximum percentage value (must be <= 100).
    */
    function setMaxPercentage(uint256 _maxPercentage) external onlyOwner {
        require(_maxPercentage <= 100, "Max percentage cannot exceed 100");
        maxPercentage = _maxPercentage;
    }

    // Function to set the ERC-20 token used for staking
    function setJokToken(address _jokToken) external onlyOwner {
        jokToken = IERC20(_jokToken);
    }
}