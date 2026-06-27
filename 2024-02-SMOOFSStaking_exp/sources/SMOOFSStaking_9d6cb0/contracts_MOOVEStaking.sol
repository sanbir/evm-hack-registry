// SPDX-License-Identifier: Two3 Labs
pragma solidity 0.8.20;

import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract SMOOFSStaking is
    IERC721Receiver,
    Initializable,
    OwnableUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    uint256 public constant AVERAGE_BLOCK_TIME = 2;

    enum NFTState {
        Staked,
        Unbonding,
        Free
    }

    IERC721 private nftCollection;
    IERC20 private rewardToken;

    uint256 private stakingEndTime;
    uint256 private unbondingPeriod;

    uint256 private rewardPerBlock;
    uint256 private earlyUnboundTax;
    uint256 private totalNFTStakeLimit;
    uint256 private nftStakeCarryAmount;

    struct StakeEntry {
        NFTState state;
        address owner;
        uint256 stakedAt;
        uint256 unbondingAt;
        uint256 lastClaimedBlock;
    }
    uint256[] private trackedNFTs;
    address[] private trackedWallets;

    mapping(uint256 => StakeEntry) private stakes;
    mapping(address => uint256[]) private stakeOwnership;

    uint256 private stakesCount;
    uint256 private activeStakesCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _nftCollectionAddress,
        address _rewardTokenAddress,
        uint256 _rewardPerBlock,
        uint256 _earlyUnbondTax,
        uint256 _totalNFTStakeLimit,
        uint256 _nftStakeCarryAmount,
        uint256 _stakingDuration,
        uint256 _unbondingPeriod
    ) external initializer {
        nftCollection = IERC721(_nftCollectionAddress);
        rewardToken = IERC20(_rewardTokenAddress);
        rewardPerBlock = _rewardPerBlock;
        earlyUnboundTax = _earlyUnbondTax;
        totalNFTStakeLimit = _totalNFTStakeLimit;
        nftStakeCarryAmount = _nftStakeCarryAmount;

        stakingEndTime = block.timestamp + _stakingDuration * 1 hours;
        unbondingPeriod = _unbondingPeriod * 1 hours;

        __Ownable_init(msg.sender);
        __AccessControl_init();
    }

    function Stake(uint256 _tokenId) public whenNotPaused {
        require(block.timestamp < stakingEndTime, "Staking period has ended");
        require(
            activeStakesCount < totalNFTStakeLimit,
            "Cannot stake more than totalNFTStakeLimit"
        );
        require(
            nftCollection.ownerOf(_tokenId) == msg.sender,
            "Only owner can stake"
        );
        //transfer tokens to contract
        rewardToken.transferFrom(
            msg.sender,
            address(this),
            nftStakeCarryAmount
        );
        //transfer nft to contract
        nftCollection.safeTransferFrom(msg.sender, address(this), _tokenId);
        activeStakesCount++;
        _addStake(
            _tokenId,
            StakeEntry({
                owner: msg.sender,
                state: NFTState.Staked,
                stakedAt: block.timestamp,
                unbondingAt: 0,
                lastClaimedBlock: block.number
            })
        );
    }

    function Unstake(uint256 _tokenId, bool forceWithTax) public whenNotPaused {
        require(block.timestamp < stakingEndTime, "Staking period has ended");
        require(stakes[_tokenId].state == NFTState.Staked, "Not staked");
        require(stakes[_tokenId].owner == msg.sender, "Not owner");
        NFTState state = stakes[_tokenId].state;
        if (forceWithTax) {
            rewardToken.transferFrom(
                msg.sender,
                address(this),
                earlyUnboundTax
            );
            state = NFTState.Free;
            stakes[_tokenId].unbondingAt = block.timestamp;
        } else {
            state = NFTState.Unbonding;
            stakes[_tokenId].unbondingAt = block.timestamp + unbondingPeriod;
        }
        ClaimReward(_tokenId);
        activeStakesCount--;
        stakes[_tokenId].state = state;
    }

    function Withdraw(
        uint256 _tokenId,
        bool forceWithTax
    ) external whenNotPaused {
        require(stakes[_tokenId].owner == msg.sender, "Not owner");
        if (block.timestamp < stakingEndTime) {
            if (block.timestamp < stakes[_tokenId].unbondingAt) {
                require(forceWithTax == true, "Requires Forced Unstaking");
            }

            if (stakes[_tokenId].state == NFTState.Staked) {
                Unstake(_tokenId, forceWithTax);
            } else if (stakes[_tokenId].state == NFTState.Unbonding) {
                rewardToken.transferFrom(
                    msg.sender,
                    address(this),
                    earlyUnboundTax
                );
                stakes[_tokenId].state = NFTState.Free;
            }
        }
        //transfer nft to owner
        nftCollection.safeTransferFrom(address(this), msg.sender, _tokenId);
        //transfer tokens to owner
        rewardToken.transfer(msg.sender, nftStakeCarryAmount);
        _removeStake(_tokenId);
    }

    function StakeList(address owner) public view returns (uint256[] memory) {
        return stakeOwnership[owner];
    }

    function StakeInfo(
        uint256 _tokenId
    ) public view returns (StakeEntry memory) {
        return stakes[_tokenId];
    }

    function UnbondingInfo(uint256 _tokenId) public view returns (uint256) {
        return stakes[_tokenId].unbondingAt;
    }

    function RewardInfo(uint256 _tokenId) public view returns (uint256) {
        require(stakes[_tokenId].state == NFTState.Staked, "Not staked");
        uint256 blockNumber = block.number;
        if (block.timestamp > stakingEndTime) {
            blockNumber =
                blockNumber -
                calculateElapsedBlocksSinceTimestamp(stakingEndTime);
        }

        uint256 blocksSinceLastClaimed = block.number -
            stakes[_tokenId].lastClaimedBlock;
        uint256 reward = blocksSinceLastClaimed *
            (rewardPerBlock / activeStakesCount);
        return reward;
    }

    function ClaimReward(uint256 _tokenId) public whenNotPaused {
        require(stakes[_tokenId].state == NFTState.Staked, "Not staked");
        require(stakes[_tokenId].owner == msg.sender, "Not owner");
        uint256 reward = RewardInfo(_tokenId);
        rewardToken.transfer(msg.sender, reward);
        stakes[_tokenId].lastClaimedBlock = block.number;
    }

    function ClaimAllRewards() public whenNotPaused {
        for (uint256 i = 0; i < stakeOwnership[msg.sender].length; i++) {
            uint256 _tokenId = stakeOwnership[msg.sender][i];
            if (stakes[_tokenId].state == NFTState.Staked)
                ClaimReward(_tokenId);
        }
    }

    function StakeCount(address owner) public view returns (uint256) {
        return stakeOwnership[owner].length;
    }

    function StakingEndTime() external view returns (uint256) {
        return stakingEndTime;
    }

    function UnbondingPeriod() external view returns (uint256) {
        return unbondingPeriod;
    }

    function RewardPerBlock() external view returns (uint256) {
        return rewardPerBlock;
    }

    function TrackedWallets() external view returns (address[] memory) {
        return trackedWallets;
    }

    function TrackedNFTs() external view returns (uint256[] memory) {
        return trackedNFTs;
    }

    function TotalStakes() external view returns (uint256) {
        return stakesCount;
    }

    function ActiveStakeCount() external view returns (uint256) {
        return activeStakesCount;
    }

    function TotalNFTStakeLimit() external view returns (uint256) {
        return totalNFTStakeLimit;
    }

    function NFTStakeCarryAmount() external view returns (uint256) {
        return nftStakeCarryAmount;
    }

    function EarlyUnboundTax() external view returns (uint256) {
        return earlyUnboundTax;
    }

    function RewardToken() external view returns (IERC20) {
        return rewardToken;
    }

    function NFTCollection() external view returns (IERC721) {
        return nftCollection;
    }

    function ForceWithdrawRewardTokens() external onlyOwner {
        rewardToken.transfer(msg.sender, rewardToken.balanceOf(address(this)));
    }

    function ForceWithdrawNFT(uint256 _tokenId) external onlyOwner {
        nftCollection.safeTransferFrom(address(this), msg.sender, _tokenId);
    }

    function _addStake(uint256 _tokenId, StakeEntry memory stake) private {
        stakes[_tokenId] = stake;
        stakeOwnership[stake.owner].push(_tokenId);
        _trackNFT(_tokenId);
        _trackWallet(stake.owner);
        stakesCount++;
    }

    function _removeStake(uint256 _tokenId) private {
        address owner = stakes[_tokenId].owner;
        //delete entry from stakeOwnership
        for (uint256 i = 0; i < stakeOwnership[owner].length; i++) {
            if (stakeOwnership[owner][i] == _tokenId) {
                stakeOwnership[owner][i] = stakeOwnership[owner][
                    stakeOwnership[owner].length - 1
                ];
                stakeOwnership[owner].pop();
                break;
            }
        }
        _untrackNFT(_tokenId);
        if (stakeOwnership[owner].length == 0) _untrackWallet(owner);
        delete stakes[_tokenId];
        stakesCount--;
    }

    function _trackNFT(uint256 _tokenId) private {
        bool found = false;
        for (uint256 i = 0; i < trackedNFTs.length; i++) {
            if (trackedNFTs[i] == _tokenId) {
                found = true;
                break;
            }
        }
        if (!found) trackedNFTs.push(_tokenId);
    }

    function _untrackNFT(uint256 _tokenId) private {
        for (uint256 i = 0; i < trackedNFTs.length; i++) {
            if (trackedNFTs[i] == _tokenId) {
                trackedNFTs[i] = trackedNFTs[trackedNFTs.length - 1];
                trackedNFTs.pop();
                break;
            }
        }
    }

    function _trackWallet(address _wallet) private {
        bool found = false;
        for (uint256 i = 0; i < trackedWallets.length; i++) {
            if (trackedWallets[i] == _wallet) {
                found = true;
                break;
            }
        }
        if (!found) trackedWallets.push(_wallet);
    }

    function SetNFTStakeLimit(uint256 _value) public onlyOwner {
        totalNFTStakeLimit = _value;
    }

    function SetRewardPerBlock(uint256 _value) public onlyOwner {
        rewardPerBlock = _value;
    }

    function SetEarlyUnboundTax(uint256 _value) public onlyOwner {
        earlyUnboundTax = _value;
    }

    function SetTotalNFTStakeLimit(uint256 _value) public onlyOwner {
        totalNFTStakeLimit = _value;
    }

    function SetNFTStakeCarryAmount(uint256 _value) public onlyOwner {
        nftStakeCarryAmount = _value;
    }

    function SetStakingEndTime(uint256 _value) public onlyOwner {
        stakingEndTime = block.timestamp + _value * 1 hours;
    }

    function SetUnbondingPeriod(uint256 _value) public onlyOwner {
        unbondingPeriod = _value * 1 hours;
    }

    function _untrackWallet(address _wallet) private {
        for (uint256 i = 0; i < trackedWallets.length; i++) {
            if (trackedWallets[i] == _wallet) {
                trackedWallets[i] = trackedWallets[trackedWallets.length - 1];
                trackedWallets.pop();
                break;
            }
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function calculateElapsedBlocksSinceTimestamp(
        uint256 pastTimestamp
    ) private view returns (uint256) {
        require(
            pastTimestamp < block.timestamp,
            "Timestamp must be in the past"
        );

        uint256 timeDiff = block.timestamp - pastTimestamp;
        uint256 elapsedBlocks = timeDiff / AVERAGE_BLOCK_TIME;
        return elapsedBlocks;
    }
}
