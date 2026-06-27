// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '../libraries/SafeOwnableUpgradeable.sol';
import '../interfaces/IBribe.sol';

interface IGauge {
    function notifyRewardAmount(IERC20 token, uint256 amount) external;
}

interface IVe {
    function vote(address user, int256 voteDelta) external;
}

// DO NOT DEPLOY IN PRODUCTION
contract MockVoter is Initializable, SafeOwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    struct LpTokenInfo {
        uint128 claimable; // 20.18 fixed point. claimable PTP
        uint128 supplyIndex; // 20.18 fixed point. distributed reward per weight
        address gauge;
        bool whitelist;
    }

    uint256 internal constant ACC_TOKEN_PRECISION = 1e15;

    IERC20 public ptp;
    IVe public vePtp;
    IERC20[] public lpTokens; // all LP tokens

    // ptp emission related storage
    uint88 public ptpPerSec; // 8.18 fixed point

    uint128 public index; // 20.18 fixed point. accumulated reward per weight
    uint40 public lastRewardTimestamp;

    // vote related storage
    uint256 public totalWeight;
    mapping(IERC20 => uint256) public weights; // lpToken => weight, equals to sum of votes for a LP token
    mapping(address => mapping(IERC20 => uint256)) public votes; // user address => lpToken => votes
    mapping(IERC20 => LpTokenInfo) internal infos; // lpToken => LpTokenInfo

    // bribe related storage
    mapping(IERC20 => address) public bribes; // lpToken => bribe rewarder

    event UpdateVote(address user, IERC20 lpToken, uint256 amount);
    event DistributeReward(IERC20 lpToken, uint256 amount);

    function initialize(
        IERC20 _ptp,
        IVe _vePtp,
        uint88 _ptpPerSec,
        uint256 _startTimestamp
    ) external initializer {
        require(_startTimestamp <= type(uint40).max, 'timestamp is invalid');
        require(address(_ptp) != address(0), 'vePtp address cannot be zero');
        require(address(_vePtp) != address(0), 'vePtp address cannot be zero');

        __Ownable_init();
        __ReentrancyGuard_init_unchained();

        ptp = _ptp;
        vePtp = _vePtp;
        ptpPerSec = _ptpPerSec;
        lastRewardTimestamp = uint40(_startTimestamp);
    }

    /// @dev this check save more gas than a modifier
    function _checkGaugeExist(IERC20 _lpToken) internal view {
        require(infos[_lpToken].gauge != address(0), 'Voter: Gauge not exist');
    }

    /// @notice returns LP tokens length
    function lpTokenLength() external view returns (uint256) {
        return lpTokens.length;
    }

    /// @notice getter function to return vote of a LP token for a user
    function getUserVotes(address _user, IERC20 _lpToken) external view returns (uint256) {
        return votes[_user][_lpToken];
    }

    /// @notice Add LP token into the Voter
    function add(
        address _gauge,
        IERC20 _lpToken,
        address _bribe
    ) external onlyOwner {
        require(infos[_lpToken].whitelist == false, 'voter: already added');
        require(_gauge != address(0));
        require(address(_lpToken) != address(0));
        require(infos[_lpToken].gauge == address(0), 'Voter: Gauge is already exist');

        infos[_lpToken].whitelist = true;
        infos[_lpToken].gauge = _gauge;
        bribes[_lpToken] = _bribe; // 0 address is allowed
        lpTokens.push(_lpToken);
    }

    function setPtpPerSec(uint88 _ptpPerSec) external onlyOwner {
        require(_ptpPerSec <= 10000e18, 'reward rate too high'); // in case of index overflow
        _distributePtp();
        ptpPerSec = _ptpPerSec;
    }

    /// @notice Pause emission of PTP tokens. Un-distributed rewards are forfeited
    /// Users can still vote/unvote and receive bribes.
    function pause(IERC20 _lpToken) external onlyOwner {
        require(infos[_lpToken].whitelist, 'voter: not whitelisted');
        _checkGaugeExist(_lpToken);

        infos[_lpToken].whitelist = false;
    }

    /// @notice Resume emission of PTP tokens
    function resume(IERC20 _lpToken) external onlyOwner {
        require(infos[_lpToken].whitelist == false, 'voter: not paused');
        _checkGaugeExist(_lpToken);

        // catch up supplyIndex
        _distributePtp();
        infos[_lpToken].supplyIndex = index;
        infos[_lpToken].whitelist = true;
    }

    /// @notice Pause emission of PTP tokens for all assets. Un-distributed rewards are forfeited
    /// Users can still vote/unvote and receive bribes.
    function pauseAll() external onlyOwner {
        _pause();
    }

    /// @notice Resume emission of PTP tokens for all assets
    function resumeAll() external onlyOwner {
        _unpause();
    }

    /// @notice get gauge address for LP token
    function setGauge(IERC20 _lpToken, address _gauge) external onlyOwner {
        require(_gauge != address(0));
        _checkGaugeExist(_lpToken);

        infos[_lpToken].gauge = _gauge;
    }

    /// @notice get bribe address for LP token
    function setBribe(IERC20 _lpToken, address _bribe) external onlyOwner {
        _checkGaugeExist(_lpToken);

        bribes[_lpToken] = _bribe; // 0 address is allowed
    }

    /// @notice Vote and unvote PTP emission for LP tokens.
    /// User can vote/unvote a un-whitelisted pool. But no PTP will be emitted.
    /// Bribes are also distributed by the Bribe contract.
    /// Amount of vote should be checked by vePtp.vote().
    /// This can also used to distribute bribes when _deltas are set to 0
    /// @param _lpVote address to LP tokens to vote
    /// @param _deltas change of vote for each LP tokens
    function vote(IERC20[] calldata _lpVote, int256[] calldata _deltas)
        external
        nonReentrant
        returns (uint256[] memory bribeRewards)
    {
        // 1. call _updateFor() to update PTP emission
        // 2. update related lpToken weight and total lpToken weight
        // 3. update used voting power and ensure there's enough voting power
        // 4. call IBribe.onVote() to update bribes
        require(_lpVote.length == _deltas.length, 'voter: array length not equal');

        // update index
        _distributePtp();

        uint256 voteCnt = _lpVote.length;
        int256 voteDelta;

        bribeRewards = new uint256[](voteCnt);

        for (uint256 i; i < voteCnt; ++i) {
            IERC20 lpToken = _lpVote[i];
            _checkGaugeExist(lpToken);

            int256 delta = _deltas[i];
            uint256 originalWeight = weights[lpToken];
            if (delta != 0) {
                _updateFor(lpToken);

                // update vote and weight
                if (delta > 0) {
                    // vote
                    votes[msg.sender][lpToken] += uint256(delta);
                    weights[lpToken] = originalWeight + uint256(delta);
                    totalWeight += uint256(delta);
                } else {
                    // unvote
                    require(votes[msg.sender][lpToken] >= uint256(-delta), 'voter: vote underflow');
                    votes[msg.sender][lpToken] -= uint256(-delta);
                    weights[lpToken] = originalWeight - uint256(-delta);
                    totalWeight -= uint256(-delta);
                }

                voteDelta += delta;
                emit UpdateVote(msg.sender, lpToken, votes[msg.sender][lpToken]);
            }

            // update bribe
            if (bribes[lpToken] != address(0)) {
                bribeRewards[i] = IBribe(bribes[lpToken]).onVote(
                    msg.sender,
                    votes[msg.sender][lpToken],
                    originalWeight
                );
            }
        }

        // notice vePTP for the new vote, it reverts if vote is invalid
        vePtp.vote(msg.sender, voteDelta);
    }

    /// @notice Claim bribes for LP tokens
    /// @dev This function looks safe from re-entrancy attack
    function claimBribes(IERC20[] calldata _lpTokens) external returns (uint256[] memory bribeRewards) {
        bribeRewards = new uint256[](_lpTokens.length);
        for (uint256 i; i < _lpTokens.length; ++i) {
            IERC20 lpToken = _lpTokens[i];
            _checkGaugeExist(lpToken);
            if (bribes[lpToken] != address(0)) {
                bribeRewards[i] = IBribe(bribes[lpToken]).onVote(
                    msg.sender,
                    votes[msg.sender][lpToken],
                    weights[lpToken]
                );
            }
        }
    }

    /// @notice Get pending bribes for LP tokens
    function pendingBribes(IERC20[] calldata _lpTokens, address _user)
        external
        view
        returns (uint256[] memory bribeRewards)
    {
        bribeRewards = new uint256[](_lpTokens.length);
        for (uint256 i; i < _lpTokens.length; ++i) {
            IERC20 lpToken = _lpTokens[i];
            if (bribes[lpToken] != address(0)) {
                bribeRewards[i] = IBribe(bribes[lpToken]).pendingTokens(_user);
            }
        }
    }

    /// @dev This function looks safe from re-entrancy attack
    function distribute(IERC20 _lpToken) external {
        _distributePtp();
        _updateFor(_lpToken);

        uint256 _claimable = infos[_lpToken].claimable;
        // `_claimable > 0` imples `_checkGaugeExist(_lpToken)`
        // In case PTP is not fueled, it should not create DoS
        if (_claimable > 0 && ptp.balanceOf(address(this)) > _claimable) {
            infos[_lpToken].claimable = 0;
            emit DistributeReward(_lpToken, _claimable);

            ptp.transfer(infos[_lpToken].gauge, _claimable);
            IGauge(infos[_lpToken].gauge).notifyRewardAmount(_lpToken, _claimable);
        }
    }

    /// @notice Update index for accrued PTP
    function _distributePtp() internal {
        if (block.timestamp > lastRewardTimestamp) {
            uint256 secondsElapsed = block.timestamp - lastRewardTimestamp;
            if (totalWeight > 0) {
                index += toUint128((secondsElapsed * ptpPerSec * ACC_TOKEN_PRECISION) / totalWeight);
            }
            lastRewardTimestamp = uint40(block.timestamp);
        }
    }

    /// @notice Update supplyIndex for the LP token
    /// @dev Assumption: gauge exists and is not paused, the caller should verify it
    /// @param _lpToken address of the LP token
    function _updateFor(IERC20 _lpToken) internal {
        uint256 weight = weights[_lpToken];
        if (weight > 0) {
            uint256 _supplyIndex = infos[_lpToken].supplyIndex;
            uint256 _index = index; // get global index for accumulated distro
            uint256 delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (delta > 0) {
                uint256 _share = (weight * delta) / ACC_TOKEN_PRECISION; // add accrued difference for each token
                infos[_lpToken].supplyIndex = toUint128(_index); // update _lpToken current position to global position

                // PTP emission for un-whitelisted lpTokens are blackholed
                // Don't distribute PTP if the contract is paused
                if (infos[_lpToken].whitelist && !paused()) {
                    infos[_lpToken].claimable += toUint128(_share);
                }
            }
        } else {
            infos[_lpToken].supplyIndex = index; // new LP tokens are set to the default global state
        }
    }

    /// @notice Update supplyIndex for the LP token
    function pendingPtp(IERC20 _lpToken) external view returns (uint256) {
        if (infos[_lpToken].whitelist == false || paused()) return 0;
        uint256 _secondsElapsed = block.timestamp - lastRewardTimestamp;
        uint256 _index = index + (_secondsElapsed * ptpPerSec * ACC_TOKEN_PRECISION) / totalWeight;
        uint256 _supplyIndex = infos[_lpToken].supplyIndex;
        uint256 _delta = _index - _supplyIndex;
        uint256 _claimable = infos[_lpToken].claimable + (weights[_lpToken] * _delta) / ACC_TOKEN_PRECISION;
        return _claimable;
    }

    /// @notice In case we need to manually migrate PTP funds from Voter
    /// Sends all remaining ptp from the contract to the owner
    function emergencyPtpWithdraw() external onlyOwner {
        // SafeERC20 is not needed as PTP will revert if transfer fails
        ptp.transfer(address(msg.sender), ptp.balanceOf(address(this)));
    }

    function toUint128(uint256 val) internal pure returns (uint128) {
        require(val <= type(uint128).max, 'uint128 overflow');
        return uint128(val);
    }

    // MOCK FUNCTION
    function resetVotes(address _user, IERC20 _lpToken) external onlyOwner {
        votes[_user][_lpToken] = 0;
    }
}
