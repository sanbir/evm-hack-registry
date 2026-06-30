// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "./IntelliQuant_Staking.sol";

contract ownable {
    address payable public Owner;

    constructor() {
        Owner = payable(0xb1d34905d794796792eFE30E08e4f24c2C06ECC1);
    }

    modifier onlyOwner() {
        require(msg.sender == Owner, "Caller is not the owner");
        _;
    }

    function transferOwnership(address payable newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner is the zero address");
        Owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        Owner = payable(address(0));
    }
}

contract AventaRewardClaim is ownable {
    IERC20 public Aventa;
    IntelliQuant_Staking public stakingContract;
    IERC20 public IntelliQuant;

    uint256 public launchTime;
    uint256 public EligibleForExtrareward;

    uint256 public timeStep = 21 days;
    uint256 public c_timeStep = 21 days;
    uint64 public eta = 7 days;
    uint64 public c_eta = 7 days;

    bool public c_paused = false;
    bool public paused = false;

    struct UserStakedData {
        uint256 withdrawnAmount;
        uint256 lastWithdrawal;
        uint256 lastWithdrawalTime;
        uint8 count;
    }

    struct UserInfo {
        uint256 withdrawnAmount;
        uint256 lastWithdrawalTime;
        uint8 count;
        uint256 initialBalance;
    }

    mapping(address => UserInfo) public info;
    mapping(uint256 => uint256) public ROI_PERCENTAGE;
    mapping(address => bool) public c_blacklist;
    mapping(address => bool) public blacklist;

    mapping(uint256 => uint256) public APR_PERCENTAGE;
    mapping(address => mapping(uint256 => UserStakedData)) public users;

    event TokensClaimed(
        address indexed user,
        uint256 amount,
        uint256 timestamp
    );
    event UserBlacklisted(address indexed user);

    modifier whenNotPaused() {
        require(!paused, "C is paused");
        _;
    }

    modifier Paused() {
        require(!paused, "is paused");
        _;
    }

    constructor() {
        stakingContract = IntelliQuant_Staking(
            payable(0xc6947307883D0e017F7d2BEd758fF114Df3f401b)
        );
        Aventa = IERC20(0x7Fd4Abc178a66E26711658763654A041940C75A9);
        IntelliQuant = IERC20(0x31Bd628c038f08537e0229f0D8c0a7b18B0CDa7B);

        APR_PERCENTAGE[14] = 100_41; //10 % APY = 0.41 percent
        APR_PERCENTAGE[30] = 101_66; //20 % APY= 1.66 percent
        APR_PERCENTAGE[60] = 105_00; //30 % APY= 5 percent
        APR_PERCENTAGE[90] = 112_50; //50% APY= 12.5 percent

        ROI_PERCENTAGE[1] = 105;
        ROI_PERCENTAGE[2] = 110;
        EligibleForExtrareward = 763556373 ether;
        launchTime = 1723053600;
    }

    // Function to pause the contract
    function c_pause() external onlyOwner {
        c_paused = true;
    }

    // Function to unpause the contract
    function c_unpause() external onlyOwner {
        c_paused = false;
    }

    function pause() external onlyOwner {
        paused = true;
    }

    // Function to unpause the contract
    function unpause() external onlyOwner {
        paused = false;
    }

    function pauseContract() external onlyOwner {
        c_paused = true;
        paused = true;
    }

    // Function to unpause the contract
    function unpauseContract() external onlyOwner {
        c_paused = false;
        paused = false;
    }

    function getOldTokenBalance(address _user) public view returns (uint256) {
        return IntelliQuant.balanceOf(_user);
    }

    function getNewTokenBalance(address _user) public view returns (uint256) {
        return Aventa.balanceOf(_user);
    }

    function c_blacklistUser(address user) external onlyOwner {
        require(!c_blacklist[user], "User is already blacklisted c");
        c_blacklist[user] = true;
    }

    function c_whitelistUser(address user) external onlyOwner {
        require(c_blacklist[user], "User is not blacklisted c");
        c_blacklist[user] = false;
    }

    function blacklistUser(address user) external onlyOwner {
        require(!blacklist[user], "User is already blacklisted");
        blacklist[user] = true;
    }

    function whitelistUser(address user) external onlyOwner {
        require(blacklist[user], "User is not blacklisted");
        blacklist[user] = false;
    }

    function setIntelliQuantAddress(address _IntelliQuant) external onlyOwner {
        IntelliQuant = IERC20(_IntelliQuant);
    }

    function setAventaAddress(address _Aventa) external onlyOwner {
        Aventa = IERC20(_Aventa);
    }

    function setLaunchTime(uint256 _launchTime) external onlyOwner {
        launchTime = _launchTime;
    }

    function setROIPercentage(
        uint256 planId,
        uint256 percentage
    ) external onlyOwner {
        ROI_PERCENTAGE[planId] = percentage;
    }

    function setAPRPercentage(uint256 _key, uint256 _value) external onlyOwner {
        APR_PERCENTAGE[_key] = _value;
    }

    function setEligibleForExtrareward(
        uint256 _extraReward
    ) external onlyOwner {
        EligibleForExtrareward = _extraReward;
    }

    function claim(address user) external whenNotPaused {
        require(!c_blacklist[user], "User is blacklisted c");
        require(user == msg.sender, "Caller is not the authorized user");

        UserInfo storage userData = info[user];

        if (userData.initialBalance == 0) {
            userData.initialBalance = getOldTokenBalance(user);
        }

        uint256 withdrawableAmount = getClaimableAmount(user);
        require(withdrawableAmount > 0, "No available");

        userData.count++;
        userData.withdrawnAmount += withdrawableAmount;
        userData.lastWithdrawalTime = block.timestamp;

        require(
            Aventa.transferFrom(Owner, user, withdrawableAmount),
            "Token transfer failed c"
        );

        if (getOldTokenBalance(user) < userData.initialBalance) {
            c_blacklist[user] = true;
            emit UserBlacklisted(user);
        }

        emit TokensClaimed(user, withdrawableAmount, block.timestamp);
    }

    function withdrawTokens(
        address user,
        uint8 duration,
        uint64 _index
    ) external Paused {
        require(user == msg.sender, "Caller is not the authorized user w");
        require(!blacklist[user], "User is blacklisted");
        UserStakedData storage userData = users[user][_index];

        (uint256 withdrawableAmount, ) = getUserDividends(
            user,
            duration,
            _index
        );
        require(withdrawableAmount > 0, "No available");
        userData.count++;
        userData.withdrawnAmount += withdrawableAmount;
        userData.lastWithdrawalTime = block.timestamp;

        if (userData.lastWithdrawal == 0) {
            userData.lastWithdrawal = block.timestamp;
        }

        require(
            Aventa.transferFrom(Owner, user, withdrawableAmount),
            "Token transfer failed"
        );
    }

    function getClaimableAmount(
        address userAddress
    ) public view returns (uint256 dividends) {
        UserInfo memory userData = info[userAddress];

        uint256 amount = getOldTokenBalance(userAddress);
        uint256 currentDividends = 0;
        uint256 startTime = launchTime + c_eta;

        if (block.timestamp >= launchTime && userData.withdrawnAmount == 0) {
            uint256 oneTimeAmount = (amount * 25) / 100;
            currentDividends += oneTimeAmount;
        }

        if (block.timestamp <= launchTime && currentDividends == 0) {
            return 0;
        }

        if (block.timestamp >= startTime) {
            uint256 ROI = (amount >= EligibleForExtrareward)
                ? ROI_PERCENTAGE[2]
                : ROI_PERCENTAGE[1];
            uint256 timeElapsed = block.timestamp - startTime;

            uint256 additionalDividends = (amount * ROI * timeElapsed) /
                (100 * c_timeStep);

            if (
                userData.withdrawnAmount +
                    currentDividends +
                    additionalDividends >
                (amount * ROI) / 100
            ) {
                additionalDividends =
                    (amount * ROI) /
                    100 -
                    userData.withdrawnAmount -
                    currentDividends;
            }

            currentDividends += additionalDividends;
        }

        return currentDividends;
    }

    function getUserDividends(
        address user,
        uint8 duration,
        uint64 index
    ) public view returns (uint256 dividends, uint256 lastWithdrew) {
        UserStakedData storage userData = users[user][index];
        (
            uint256 depositAmount,
            uint256 TIME_STEP,
            uint256 depositTime
        ) = getUserInformation(user, index);

        uint256 timeElapsed;
        uint256 currentDividends;

        uint256 startTime = userData.lastWithdrawal + eta;

        if (userData.lastWithdrawal == 0 && currentDividends == 0) {
            timeElapsed = block.timestamp - depositTime;
            currentDividends =
                (depositAmount * APR_PERCENTAGE[duration] * timeElapsed) /
                (100_00 * TIME_STEP);
        }

        if (block.timestamp >= startTime) {
            timeElapsed = block.timestamp - userData.lastWithdrawal;
            currentDividends =
                (depositAmount * APR_PERCENTAGE[duration] * timeElapsed) /
                (100_00 * timeStep);
        }

        uint256 maxDividends = (depositAmount * APR_PERCENTAGE[duration]) /
            100_00;
        if (userData.withdrawnAmount + currentDividends > maxDividends) {
            currentDividends = maxDividends - userData.withdrawnAmount;
        }

        if (userData.count == 0) {
            currentDividends = currentDividends / 4;
        }

        return (currentDividends, userData.lastWithdrawalTime);
    }

    function getUserInformation(
        address _user,
        uint256 _index
    )
        public
        view
        returns (
            uint256 depositAmount,
            uint256 lockableDays,
            uint256 depositTime
        )
    {
        (
            uint256[] memory deposits,
            uint256[] memory lockableDaysArr,
            uint256[] memory depositTimes
        ) = stakingContract.UserInformation(_user);

        return (
            deposits[_index],
            lockableDaysArr[_index],
            depositTimes[_index]
        );
    }

    function getDepositsLength(address _user) public view returns (uint256) {
        (uint256[] memory deposits, , ) = stakingContract.UserInformation(
            _user
        );
        return deposits.length;
    }

    function setTimeStep(uint256 _timeStep) external onlyOwner {
        timeStep = _timeStep;
    }

    function setc_TimeStep(uint256 _CtimeStep) external onlyOwner {
        c_timeStep = _CtimeStep;
    }

    function setEta(uint64 _eta) external onlyOwner {
        eta = _eta;
    }

    function setC_Eta(uint64 _C_eta) external onlyOwner {
        c_eta = _C_eta;
    }

    function setStakingContract(
        IntelliQuant_Staking _stakingContract
    ) external onlyOwner {
        stakingContract = _stakingContract;
    }

    function withdrawTokens(IERC20 _token, uint256 _amount) external onlyOwner {
        _token.transfer(msg.sender, _amount);
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        payable(msg.sender).transfer(amount);
    }

    receive() external payable {}
}
