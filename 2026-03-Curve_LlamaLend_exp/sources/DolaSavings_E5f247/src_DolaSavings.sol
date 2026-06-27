// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.21;

interface IERC20 {
    function transfer(address, uint) external returns (bool);
    function transferFrom(address, address, uint) external returns (bool);
    function balanceOf(address) external view returns (uint);
}

interface IDBR {
    function mint(address, uint) external;
}

/**
 * @title DolaSavings
 * @dev Smart contract for staking DOLA tokens to earn DBR rewards.
 */
contract DolaSavings {

    IDBR public immutable dbr;
    IERC20 public immutable dola;
    address public gov;
    address public pendingGov;
    address public operator;
    uint public constant mantissa = 10**18;
    uint public maxYearlyRewardBudget;
    uint public maxRewardPerDolaMantissa = 10**18; // 1 DBR per DOLA
    uint public yearlyRewardBudget; // starts at 0
    uint public lastUpdate;
    uint public rewardIndexMantissa;
    uint public totalSupply;
    
    mapping (address => uint) public balanceOf;
    mapping (address => uint) public stakerIndexMantissa;
    mapping (address => uint) public accruedRewards;
 
    /**
     * @dev Modifier to update the reward index for the whole contract as well as for a specific user.
     * Calculates rewards based on the time elapsed and the total supply staked.
     * @param user Address of the user for whom to update the index.
     */
    modifier updateIndex(address user) {
        uint deltaT = block.timestamp - lastUpdate;
        if(deltaT > 0) {
            if(yearlyRewardBudget > 0 && totalSupply > 0) {
                uint _totalSupply = totalSupply;
                uint _yearlyRewardBudget = yearlyRewardBudget;
                uint maxBudget = maxRewardPerDolaMantissa * _totalSupply / mantissa;
                uint budget = _yearlyRewardBudget > maxBudget ? maxBudget : _yearlyRewardBudget;
                uint rewardsAccrued = deltaT * budget * mantissa / 365 days;
                rewardIndexMantissa += rewardsAccrued / _totalSupply;
            }
            lastUpdate = block.timestamp;
        }

        uint deltaIndex = rewardIndexMantissa - stakerIndexMantissa[user];
        uint bal = balanceOf[user];
        uint stakerDelta = bal * deltaIndex;
        stakerIndexMantissa[user] = rewardIndexMantissa;
        accruedRewards[user] += stakerDelta / mantissa;
        _;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "ONLY GOV");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "ONLY OPERATOR");
        _;
    }

    /**
     * @dev Constructor for DolaSavings.
     * @param _dbr Address of the DBR token contract.
     * @param _dola Address of the DOLA token contract.
     * @param _gov Address of governance.
     * @param _operator Address of the operator.
     */
    constructor (address _dbr, address _dola, address _gov, address _operator) {
        dbr = IDBR(_dbr);
        dola = IERC20(_dola);
        gov = _gov;
        operator = _operator;
        lastUpdate = block.timestamp;
    }

    function setOperator(address _operator) external onlyGov { operator = _operator; }
    function setPendingGov(address _gov) external onlyGov { pendingGov = _gov; }
    function acceptGov() external {
        require(msg.sender == pendingGov, "Only pendingGov");
        gov = pendingGov;
        pendingGov = address(0);
    }

    /**
     * @dev Sets the maximum yearly reward budget.
     * @param _max The maximum yearly reward budget.
     */
    function setMaxYearlyRewardBudget(uint _max) external onlyGov updateIndex(msg.sender) {
        maxYearlyRewardBudget = _max;
        if(yearlyRewardBudget > _max) {
            yearlyRewardBudget = _max;
            emit SetYearlyRewardBudget(_max);
        }
        emit SetMaxYearlyRewardBudget(_max);
    }

    /**
     * @dev Sets the maximum reward per DOLA in mantissa.
     * @param _max The maximum reward per DOLA in mantissa.
     */
    function setMaxRewardPerDolaMantissa(uint _max) external onlyGov updateIndex(msg.sender) {
        require(_max < type(uint).max / (mantissa * 10 ** 13)); //May overflow if set to max and more than 10 trillion DOLA has been deposited
        maxRewardPerDolaMantissa = _max;
        emit SetMaxRewardPerDolaMantissa(_max);
    }

    /**
     * @dev Sets the yearly reward budget.
     * @param _yearlyRewardBudget The yearly reward budget.
     */
    function setYearlyRewardBudget(uint _yearlyRewardBudget) external onlyOperator updateIndex(msg.sender) {
        require(_yearlyRewardBudget <= maxYearlyRewardBudget, "REWARD BUDGET ABOVE MAX");
        yearlyRewardBudget = _yearlyRewardBudget;
        emit SetYearlyRewardBudget(_yearlyRewardBudget);
    }

    /**
     * @dev Stakes DOLA tokens.
     * @param amount The amount of DOLA tokens to stake.
     * @param recipient The address of the recipient.
     */
    function stake(uint amount, address recipient) external updateIndex(recipient) {
        require(recipient != address(0), "Zero address");
        balanceOf[recipient] += amount;
        totalSupply += amount;
        dola.transferFrom(msg.sender, address(this), amount);
        emit Stake(msg.sender, recipient, amount);
    }

    /**
     * @dev Unstakes DOLA tokens.
     * @param amount The amount of DOLA tokens to unstake.
     */
    function unstake(uint amount) external updateIndex(msg.sender) {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        dola.transfer(msg.sender, amount);
        emit Unstake(msg.sender, amount);
    }

    /**
     * @dev Calculates the claimable rewards for a user.
     * @param user The address of the user.
     * @return The amount of claimable rewards.
     */
    function claimable(address user) external view returns(uint) {
        uint _totalSupply = totalSupply;
        uint _yearlyRewardBudget = yearlyRewardBudget;
        uint _rewardIndexMantissa = rewardIndexMantissa;
        uint deltaT = block.timestamp - lastUpdate;
        uint maxBudget = maxRewardPerDolaMantissa * _totalSupply / mantissa;
        uint budget = _yearlyRewardBudget > maxBudget ? maxBudget : _yearlyRewardBudget;
        uint rewardsAccrued = deltaT * budget * mantissa / 365 days;
        _rewardIndexMantissa = _totalSupply > 0 ? _rewardIndexMantissa + rewardsAccrued / _totalSupply : _rewardIndexMantissa;
        uint deltaIndex = _rewardIndexMantissa - stakerIndexMantissa[user];
        uint bal = balanceOf[user];
        uint stakerDelta = bal * deltaIndex / mantissa;
        return (accruedRewards[user] + stakerDelta);
    }

    /**
     * @dev Claims the accrued rewards of the msg.sender and mints DBR tokens to the specified address.
     * @param to The address to receive the claimed DBR tokens.
     */
    function claim(address to) external updateIndex(msg.sender) {
        uint accrued = accruedRewards[msg.sender];
        dbr.mint(to, accrued);
        accruedRewards[msg.sender] = 0;
        emit Claim(msg.sender, to, accrued);
    }

    /**
     * @dev Transfers out any ERC20 tokens from the contract.
     * Ensures that user staked DOLA cannot be swept.
     * @param token The address of the ERC20 token to sweep.
     * @param amount The amount of tokens to sweep.
     * @param to The recipient address of the swept tokens.
     */
    function sweep(address token, uint amount, address to) external onlyGov {
        if(token == address(dola)) {
            require(IERC20(token).balanceOf(address(this)) - totalSupply >= amount, "CANNOT SWEEP USER DOLA");
        }
        IERC20(token).transfer(to, amount);
    }

    event Stake(address indexed caller, address indexed recipient, uint amount);
    event Unstake(address indexed caller, uint amount);
    event Claim(address indexed caller, address indexed recipient, uint claimed);

    event SetYearlyRewardBudget(uint newYearlyRewardBudget);
    event SetMaxRewardPerDolaMantissa(uint newMax);
    event SetMaxYearlyRewardBudget(uint newMax);
}
