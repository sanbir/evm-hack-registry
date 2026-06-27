//  _____  _  _              _        _   _____  _          _     _               
// /  __ \(_)| |            | |      | | /  ___|| |        | |   (_)              
// | /  \/ _ | |_  __ _   __| |  ___ | | \ `--. | |_  __ _ | | __ _  _ __    __ _ 
// | |    | || __|/ _` | / _` | / _ \| |  `--. \| __|/ _` || |/ /| || '_ \  / _` |
// | \__/\| || |_| (_| || (_| ||  __/| | /\__/ /| |_| (_| ||   < | || | | || (_| |
//  \____/|_| \__|\__,_| \__,_| \___||_| \____/  \__|\__,_||_|\_\|_||_| |_| \__, |
//                                                                           __/ |
//                                                                          |___/ 

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ICIT.sol";
import "./interfaces/IBCIT.sol";
import "./interfaces/ICITReferral.sol";

contract CitadelStaking is Ownable, ReentrancyGuard {
    //----------------------VARIABLES----------------------//

    IBCIT public bCIT;
    ICIT public CIT;
    ICITReferral internal CITReferral;

    address private CITRedeem;

    uint256 private depositFee = 2; // 2%
    uint256 private withdrawFee = 6; // 6%
    uint256 private depositFeeWithReferral = 1; // 1%

    uint256 public epochDuration = 6 hours; // 10 min for test, 6hrs for prod
    uint256 public fullDistributionEpochs = 28; // 28 * 6 hours = 7 days
    uint256 private genesisEpochTime;
    bool private isStarted = false;

    uint256 public fixedRate;

    uint256 public totalStakedCIT = 0;
    uint256 public totalStakedbCIT = 0;
    uint256 public rewardsPerEpoch = 500 * 1e18; // 500 CIT per epoch

    struct Staking {
        address token;
        uint256 amount;
        uint256 redeemAmount;
        uint256 fixedRateAtStaking;
        uint256 epoch;
        uint8 rate;
        bool hasClaimedAtLeastOnce;
    }

    struct User {
        uint256[2] CITStaking;
        uint256[2] bCITStaking;
        uint256 lastClaim;
    }

    struct Epoch {
        uint256 epoch;
        bool initialized;
        uint256 totalStaked;
        uint256 rewards;
    }

    mapping(address => Staking[]) public stakings;
    mapping(address => User) private users;
    mapping(uint256 => Epoch) public epochs;
    mapping(address => uint256) private totalPendingStakingRewardsForUser;
    mapping(address => uint256) private totalClaimedByUser;
    mapping(address => uint256) private totalReferralRewardsClaimed;

    //----------------------CONSTRUCTOR----------------------//

    constructor(
        address initialOwner,
        address _bCIT,
        address _CITReferral
    ) Ownable(initialOwner) {
        bCIT = IBCIT(_bCIT);
        CITReferral = ICITReferral(_CITReferral);
    }

    //----------------------SETTERS----------------------//

    function setFixedRate(uint256 _fixedRate) public onlyOwner {
        fixedRate = _fixedRate;
    }

    function setCIT(address _CIT) public onlyOwner {
        CIT = ICIT(_CIT);
    }

    function setCITRedeemAddy(address _CITRedeem) public onlyOwner {
        CITRedeem = _CITRedeem;
    }

    function setFees(
        uint256 _depositFee,
        uint256 _withdrawFee
    ) public onlyOwner {
        depositFee = _depositFee;
        withdrawFee = _withdrawFee;
    }

    function setEpochDuration(uint256 _epochDuration) public onlyOwner {
        epochDuration = _epochDuration;
    }

    function setFullDistributionEpochs(
        uint256 _fullDistributionEpochs
    ) public onlyOwner {
        fullDistributionEpochs = _fullDistributionEpochs;
    }

    function setRewardPerEpoch(uint256 _rewardsPerEpoch) public onlyOwner {
        rewardsPerEpoch = _rewardsPerEpoch;
    }

    function approveCITnbCIT(uint256 amount) public onlyOwner {
        CIT.approve(CITRedeem, amount);
        bCIT.approve(CITRedeem, amount);
    }

    //----------------------USERS FUNCTIONS----------------------//

    /**
     * @dev starts the first epoch counter and opens staking deposits
     */
    function startEpoch() public onlyOwner {
        require(!isStarted, "Epoch already started");
        genesisEpochTime = block.timestamp;
        epochs[0] = Epoch(0, true, 0, rewardsPerEpoch);
        isStarted = true;
    }

    /**
     * @dev Allows users to deposit CIT or bCIT for staking
     * @param token the addy of the token to deposit
     * @param amount the amount to deposit
     * @param rate rate, either fixed or variable - 0 for variable, 1 for fixed
     */
    function deposit(
        address token,
        uint256 amount,
        uint8 rate
    ) public nonReentrant {
        _deposit(msg.sender, token, amount, rate);
    }

    /**
     * @dev Allows users to withdraw CIT or bCIT from staking
     * @param token the addy of the token to withdraw
     * @param amount the amount to withdraw
     * @param rate the rate staking to withdraw from, either fixed or variable - 0 for variable, 1 for fixed
     */
    function withdraw(
        address token,
        uint256 amount,
        uint8 rate
    ) external nonReentrant {
        require(
            token == address(bCIT) || token == address(CIT),
            "Invalid token"
        );
        require(rate == 0 || rate == 1, "Invalid rate");

        if (rewardsCalculator(msg.sender) > 0) {
            _claim(msg.sender);
        }

        uint256 amountAfterFee = amount;

        if (token == address(bCIT)) {
            require(
                amount <= users[msg.sender].bCITStaking[rate],
                "Not enough staked"
            );
            totalStakedbCIT -= amount;
            bCIT.transfer(msg.sender, amount);
            users[msg.sender].bCITStaking[rate] -= amount;
        } else if (token == address(CIT)) {
            require(
                amount <= users[msg.sender].CITStaking[rate],
                "Not enough staked"
            );
            totalStakedCIT -= amount;
            uint256 fee = (amount * withdrawFee) / 100;
            amountAfterFee = amount - fee;
            CIT.transfer(msg.sender, amountAfterFee);

            CIT.transfer(address(CIT), fee);
            users[msg.sender].CITStaking[rate] -= amount;
        }

        _deductFromStaking(msg.sender, token, rate, amount, false);
        _epochDataSave(_getEpoch());
    }

    /**
     * @dev Allows users to claim CIT staking rewards
     */
    function claim() public nonReentrant {
        _claim(msg.sender);
    }

    /**
     * @dev Allows users to compound CIT staking rewards with the desired rate
     * @param rate rate, either fixed or variable
     */
    function compound(uint8 rate) external nonReentrant {
        require(rate == 0 || rate == 1, "Invalid rate");
        uint256 pendingRewards = _claim(msg.sender);
        _deposit(msg.sender, address(CIT), pendingRewards, rate);
    }

    /**
     * @dev Allows users to claim referral rewards
     */
    function claimReferralRewards() external nonReentrant {
        uint256 availableRewards = referralRewardsCalculator(msg.sender);
        require(availableRewards > 0, "Nothing to claim");
        totalReferralRewardsClaimed[msg.sender] += availableRewards;
        CIT.mint(msg.sender, availableRewards);
    }

    //----------------------CALCULATORS----------------------//

    /**
     * @dev returns the amount of CIT and bCIT that can be redeemed in total by the user (it does not count the amount already redeemed)
     * @param user the user to calculate redeemable amounts for
     */
    function redeemCalculator(
        address user
    ) public view returns (uint256[2][2] memory) {
        uint256 currentEpoch = _getEpoch();
        uint256[2] memory redeemableAmountsCIT = [uint256(0), uint256(0)];
        uint256[2] memory redeemableAmountsBCIT = [uint256(0), uint256(0)];

        uint256 _fullDistributionEpochs = fullDistributionEpochs;
        if (CITReferral.getReferrer(user) != address(0)) {
            _fullDistributionEpochs = 24;
        }

        for (uint256 i = 0; i < stakings[user].length; i++) {
            Staking memory staking = stakings[user][i];
            uint256 epochsPassed = currentEpoch - staking.epoch;
            epochsPassed = epochsPassed > _fullDistributionEpochs
                ? _fullDistributionEpochs
                : epochsPassed;

            uint256 amountToRedeem = ((staking.amount * epochsPassed) /
                _fullDistributionEpochs) - staking.redeemAmount;

            if (staking.rate == 0) {
                if (staking.token == address(CIT)) {
                    redeemableAmountsCIT[0] += amountToRedeem;
                } else {
                    redeemableAmountsBCIT[0] += amountToRedeem;
                }
            } else if (staking.rate == 1) {
                if (staking.token == address(CIT)) {
                    redeemableAmountsCIT[1] += amountToRedeem;
                } else {
                    redeemableAmountsBCIT[1] += amountToRedeem;
                }
            }
        }

        return [redeemableAmountsCIT, redeemableAmountsBCIT];
    }

    /**
     * @dev returns the amount of pending staking rewards for the user
     * @param user the user to calculate rewards for
     */
    function rewardsCalculator(address user) public view returns (uint256) {
        uint256 currentEpoch = _getEpoch();
        uint256 totalRewards = 0;

        for (uint256 i = 0; i < stakings[user].length; i++) {
            Staking memory staking = stakings[user][i];

            uint256 epochFromCalculateRewards = staking.hasClaimedAtLeastOnce
                ? users[user].lastClaim
                : staking.epoch;
            uint256 epochsPassedSinceLastClaim = currentEpoch -
                epochFromCalculateRewards;

            for (uint256 j = 0; j < epochsPassedSinceLastClaim; j++) {
                uint256 epochIndex = epochFromCalculateRewards + j;
                uint256 epochTotalStaked = _getValidTotalStaked(epochIndex);
                uint256 epochRewards = _getValidEpochRewards(epochIndex);

                if (epochTotalStaked > 0) {
                    totalRewards +=
                        (staking.amount * epochRewards) /
                        epochTotalStaked;
                }
            }
        }
        return totalRewards;
    }

    /**
     * @dev returns the amount of rewards for the next epoch for the user
     * @param user the user to calculate rewards for
     */
    function nextEpochRewardForUserCalculator(
        address user
    ) public view returns (uint256) {
        uint256 nextRewards = 0;
        uint256 currentEpoch = _getEpoch();
        uint256 currentStaked = epochs[currentEpoch].totalStaked != 0
            ? epochs[currentEpoch].totalStaked
            : totalStakedCIT + totalStakedbCIT;

        if (currentStaked == 0) {
            return 0;
        }

        for (uint256 i = 0; i < stakings[user].length; i++) {
            Staking memory staking = stakings[user][i];
            nextRewards += (staking.amount * rewardsPerEpoch) / currentStaked;
        }
        return nextRewards;
    }

    /**
     *  @dev returns the amount of pending referral rewards for the user
     * @param user the user to calculate referral rewards for
     */
    function referralRewardsCalculator(
        address user
    ) public view returns (uint256) {
        uint256 totalClaimedByReferrals = 0;
        address[] memory referrals = CITReferral.getReferrals(user);

        for (uint256 i = 0; i < referrals.length; i++) {
            totalClaimedByReferrals += totalClaimedByUser[referrals[i]];
        }
        uint256 referralRewards = (totalClaimedByReferrals * 5) / 100;
        uint256 availableRewards = referralRewards -
            totalReferralRewardsClaimed[user];

        return availableRewards;
    }

    function getCITInUSDAllFixedRates(
        address user,
        uint256 amount
    ) external view returns (uint256) {
        uint256 amountAvailable = redeemCalculator(user)[0][1] +
            redeemCalculator(user)[1][1];
        require(amount <= amountAvailable, "Not enough CIT or bCIT to redeem");
        uint256 amountToConvert = amount;
        uint256 USDEquivalent = 0;

        for (uint256 i = 0; i < stakings[user].length; i++) {
            Staking memory staking = stakings[user][i];

            if (staking.rate == 1 && amountToConvert > 0) {
                uint256 _amountToConvert = amountToConvert > staking.amount
                    ? staking.amount
                    : amountToConvert;
                amountToConvert -= _amountToConvert;
                USDEquivalent +=
                    (_amountToConvert * staking.fixedRateAtStaking) /
                    1e18;
            }
        }

        return USDEquivalent;
    }

    /**
     * @dev returns the total amount of CIT and bCIT staked for the user
     * @param user the user
     * @param rate the rate to get the total staked for - 0 for variable, 1 for fixed
     * @param token the token to get the total staked for
     */
    function getTotalTokenStakedForUser(
        address user,
        uint8 rate,
        address token
    ) public view returns (uint256) {
        if (token == address(CIT)) {
            return users[user].CITStaking[rate];
        } else if (token == address(bCIT)) {
            return users[user].bCITStaking[rate];
        } else {
            return 0;
        }
    }

    /**
     * @dev returns current epoch
     */
    function _getEpoch() internal view returns (uint256) {
        return (block.timestamp - genesisEpochTime) / epochDuration;
    }

    /**
     * @dev returns next epoch
     */
    function getNextEpoch() public view returns (uint256) {
        return genesisEpochTime + (_getEpoch() + 1) * epochDuration;
    }

    function _epochDataSave(uint256 _epoch) private {
        if (!epochs[_epoch].initialized) {
            epochs[_epoch] = Epoch(
                _epoch,
                true,
                totalStakedCIT + totalStakedbCIT,
                rewardsPerEpoch
            );
        } else {
            epochs[_epoch].totalStaked = totalStakedCIT + totalStakedbCIT;
        }
    }

    //----------------------INTERNAL FUNCTIONS----------------------//

    function _deposit(
        address user,
        address token,
        uint256 amount,
        uint8 rate
    ) private {
        require(isStarted, "Epoch not started");
        require(
            token == address(bCIT) || token == address(CIT),
            "Invalid token"
        );
        require(rate == 0 || rate == 1, "Invalid rate");
        uint256 currentEpoch = _getEpoch();
        uint256 amountAfterFee = amount;

        if (token == address(bCIT)) {
            totalStakedbCIT += amount;
            bCIT.transferFrom(user, address(this), amount);
            users[user].bCITStaking[rate] += amount;
        } else if (token == address(CIT)) {
            uint256 _depositFee = depositFee;
            if (CITReferral.getReferrer(user) != address(0)) {
                _depositFee = depositFeeWithReferral;
            }
            uint256 fee = (amount * _depositFee) / 100;
            amountAfterFee = amount - fee;
            totalStakedCIT += amountAfterFee;
            CIT.transferFrom(user, address(this), amount);

            CIT.transfer(address(CIT), fee);
            users[user].CITStaking[rate] += amountAfterFee;
        }

        stakings[user].push(
            Staking(
                token,
                amountAfterFee,
                0,
                fixedRate,
                currentEpoch,
                rate,
                false
            )
        );
        _epochDataSave(currentEpoch);
    }

    function _claim(address user) private returns (uint256) {
        uint256 pendingRewards = rewardsCalculator(user);
        require(pendingRewards > 0, "Nothing to claim");

        uint256 currentEpoch = _getEpoch();

        for (uint256 i = 0; i < stakings[user].length; i++) {
            // Saving gas by not looping through all epochs
            if (!stakings[user][i].hasClaimedAtLeastOnce) {
                stakings[user][i].hasClaimedAtLeastOnce = true;
            }
        }

        CIT.mint(user, pendingRewards);

        users[user].lastClaim = currentEpoch;
        totalClaimedByUser[user] += pendingRewards;

        return pendingRewards;
    }

    function _getValidTotalStaked(
        uint256 epochIndex
    ) private view returns (uint256) {
        while (epochIndex > 0 && epochs[epochIndex].totalStaked == 0) {
            epochIndex--;
        }
        return epochs[epochIndex].totalStaked;
    }

    function _getValidEpochRewards(
        uint256 epochIndex
    ) private view returns (uint256) {
        while (epochIndex > 0 && epochs[epochIndex].rewards == 0) {
            epochIndex--;
        }
        return epochs[epochIndex].rewards;
    }

    /**
     * @dev deducts the amount from the staking (helper function for withdraw and redeem)
     * @param user the user to deduct from
     * @param token the token to deduct staking from
     * @param rate the rate staking to deduct from
     * @param amount the amount to deduct
     * @param isRedeem if the function is called from redeem
     */
    function _deductFromStaking(
        address user,
        address token,
        uint8 rate,
        uint256 amount,
        bool isRedeem
    ) private {
        uint256 amountToDeductStaking = amount;

        for (uint256 i = 0; i < stakings[user].length; i++) {
            Staking storage staking = stakings[user][i];

            if (staking.token == token && staking.rate == rate) {
                if (amountToDeductStaking <= staking.amount) {
                    if (isRedeem) {
                        staking.redeemAmount += amountToDeductStaking;
                    }
                    staking.amount -= amountToDeductStaking;
                    amountToDeductStaking = 0;
                    break;
                } else {
                    if (isRedeem) {
                        staking.redeemAmount += staking.amount;
                    }
                    amountToDeductStaking -= staking.amount;
                    staking.amount = 0;
                }
            }
        }
    }

    /**
     * @dev removes the amount from the staking (helper function for redeem)
     * @param token the token to remove staking from
     * @param rate the rate staking to remove from
     * @param amount the amount to remove
     */
    function removeStaking(
        address user,
        address token,
        uint8 rate,
        uint256 amount
    ) external {
        require(msg.sender == CITRedeem, "Not authorized");
        _deductFromStaking(user, token, rate, amount, true);
        if (token == address(CIT)) {
            totalStakedCIT -= amount;
            users[user].CITStaking[rate] -= amount;
        } else if (token == address(bCIT)) {
            totalStakedbCIT -= amount;
            users[user].bCITStaking[rate] -= amount;
        }
    }

    //----------------------GETTERS----------------------//

    function getCurrentEpoch() external view returns (uint256) {
        return _getEpoch();
    }

    function getFixedRate() public view returns (uint256) {
        return fixedRate;
    }

    function getUsers(address user) external view returns (uint256) {
        uint256 sum = 0;

        sum =
            users[user].CITStaking[0] +
            users[user].CITStaking[1] +
            users[user].bCITStaking[0] +
            users[user].bCITStaking[1];

        return sum;
    }
}
