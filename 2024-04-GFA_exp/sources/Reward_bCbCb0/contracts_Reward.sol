// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

contract Context {
    // Empty internal constructor, to prevent people from mistakenly deploying
    // an instance of this contract, which should be used via inheritance.
    constructor() {}

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    function _msgData() internal view returns (bytes memory) {
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

contract Reward is Context {
    using SafeMath for uint256;
    struct RewardData {
        address reward;
        uint256 amount;
        uint256 remain;
        uint256 price;
        uint256 timestemp;
    }

    struct RewardHistory {
        uint256 amount;
        uint256 goldAmount;
        uint256 coinAmount;
        uint256 price;
        uint256 timesptemp;
    }

    uint256 _totalMineCnt = 0;
    uint256 _totalRemainCnt = 0;
    uint256 _mineDaliyRatio;
    uint256 _fixMineCoinRatio = 30;
    uint256 _decimals;
    mapping(address => RewardData[]) reward;
    address[] rewardKeys;
    mapping(address => uint256) waitRelease;
    mapping(address => RewardHistory[]) history;
    mapping(address => uint256) historyTotal;

    address _mainPair;

    function init(
        uint256 mineDaliyRatio,
        uint256 decimals,
        address mainPair
    ) public {
        _mineDaliyRatio = mineDaliyRatio;
        _decimals = decimals;
        _mainPair = mainPair;
    }

    function setReward(
        address rewardSender,
        uint256 amount,
        uint256 remain,
        uint256 price
    ) public {
        if (reward[rewardSender].length == 0) {
            rewardKeys.push(rewardSender);
        }

        reward[rewardSender].push(
            RewardData(rewardSender, amount, remain, price, block.timestamp)
        );
        _totalRemainCnt += remain;
    }

    event CoinReward(
        address adr,
        uint256 amount,
        uint256 price,
        uint256 sameCoin,
        uint256 finxMineCoin
    );

    function generateReward(uint256 coinPrice) public {
        coinPrice = coinPrice == 0 ? 1 * 10**_decimals : coinPrice;
        for (uint256 i = 0; i < rewardKeys.length; i++) {
            for (uint256 j = 0; j < reward[rewardKeys[i]].length; j++) {
                if (reward[rewardKeys[i]][j].remain == 0) {
                    continue;
                }

                uint256 pawnPrice = reward[rewardKeys[i]][j].price;
                uint256 targetRelease = reward[rewardKeys[i]][j].amount.mul(
                    _mineDaliyRatio
                ) / 100;
                uint256 fixMineCoin = targetRelease.mul(_fixMineCoinRatio).div(
                    100
                );
                uint256 sameCoinValue = (
                    ((targetRelease - fixMineCoin) * pawnPrice).div(coinPrice)
                );

                uint256 release = sameCoinValue + fixMineCoin;
                if (reward[rewardKeys[i]][j].remain < release) {
                    release = reward[rewardKeys[i]][j].remain;
                }

                if (waitRelease[rewardKeys[i]] != 0) {
                    waitRelease[rewardKeys[i]] += release;
                } else {
                    waitRelease[rewardKeys[i]] = release;
                }

                if (historyTotal[rewardKeys[i]] != 0) {
                    historyTotal[rewardKeys[i]] += release;
                } else {
                    historyTotal[rewardKeys[i]] = release;
                }
                reward[rewardKeys[i]][j].remain =
                    reward[rewardKeys[i]][j].remain -
                    release;
                history[rewardKeys[i]].push(
                    RewardHistory(
                        release,
                        sameCoinValue,
                        fixMineCoin,
                        coinPrice,
                        block.timestamp
                    )
                );
                _totalMineCnt += release;
                emit CoinReward(
                    rewardKeys[i],
                    release,
                    coinPrice,
                    sameCoinValue,
                    fixMineCoin
                );
            }
        }
    }

    function releaseCoin(address sender) public returns (uint256) {
        uint256 release = waitRelease[sender];
        waitRelease[sender] = 0;
        _totalRemainCnt -= release;
        return release;
    }

    function getWaitReleaseCoin(address sender) public view returns (uint256) {
        return waitRelease[sender];
    }

    function getRewardList(address sender)
        public
        view
        returns (RewardData[] memory)
    {
        return reward[sender];
    }

    function getRewardAddressList() public view returns (address[] memory) {
        return rewardKeys;
    }

    function getHistory(address sender)
        public
        view
        returns (RewardHistory[] memory)
    {
        return history[sender];
    }

    function getHistoryMineTotal(address sender) public view returns (uint256) {
        return historyTotal[sender];
    }

    function getTotalMineCnt() external view returns (uint256) {
        return _totalMineCnt;
    }

    function getTotalRemainCnt() external view returns (uint256) {
        return _totalRemainCnt;
    }
}
