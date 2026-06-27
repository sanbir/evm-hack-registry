// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./interfaces/IApeCoinStaking.sol";
import "./interfaces/IApePool.sol";
import "./interfaces/IPTokenApeStaking.sol";
import "./interfaces/ITokenLending.sol";
import "./interfaces/INftGateway.sol";
import "./ApeStakingStorage.sol";

/**
 * @title Pawnfi's ApeStaking Contract
 * @author Pawnfi
 */
contract ApeStaking is ERC721HolderUpgradeable, ReentrancyGuardUpgradeable, AccessControlUpgradeable, ApeStakingStorage {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    function initialize(
        address apePool_,
        address nftGateway_,
        address pawnToken_,
        address feeTo_,
        StakingConfiguration memory stakingConfiguration_
    ) public initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(REINVEST_ROLE, msg.sender);
        apeCoinStaking = IApePool(apePool_).apeCoinStaking();
        apePool = apePool_;
        nftGateway = nftGateway_;
        pawnToken = pawnToken_;
        feeTo = feeTo_;
        stakingConfiguration = stakingConfiguration_;

        apeCoin = IApeCoinStaking(apeCoinStaking).apeCoin();
        ( , pbaycAddr, , , ) = INftGateway(nftGateway_).marketInfo(BAYC_ADDR);
        ( , pmaycAddr, , , ) = INftGateway(nftGateway_).marketInfo(MAYC_ADDR);
        ( , pbakcAddr, , , ) = INftGateway(nftGateway_).marketInfo(BAKC_ADDR);

        _nftInfo[BAYC_ADDR].poolId = BAYC_POOL_ID;
        _nftInfo[MAYC_ADDR].poolId = MAYC_POOL_ID;
        _nftInfo[BAKC_ADDR].poolId = BAKC_POOL_ID;

        IERC721Upgradeable(BAYC_ADDR).setApprovalForAll(pbaycAddr, true);
        IERC721Upgradeable(MAYC_ADDR).setApprovalForAll(pmaycAddr, true);
        IERC721Upgradeable(BAKC_ADDR).setApprovalForAll(pbakcAddr, true);
    }

    /**
     * @notice Get IDs of staked NFTs
     * @param nftAsset nft asset address
     * @return nftIds nft id array
     */
    function getStakeNftIds(address nftAsset) external view returns (uint256[] memory nftIds) {
        uint256 length = _nftInfo[nftAsset].stakeIds.length();
        nftIds = new uint256[](length);
        for(uint256 i = 0; i < length; i++) {
            nftIds[i] = _nftInfo[nftAsset].stakeIds.at(i);
        }
    }

    /**
     * @notice Get user info
     * @param userAddr User address
     * @param nftAsset nft asset address
     * @return collectRate Collect rate
     * @return iTokenAmount iToken amount
     * @return pTokenAmount Amount of P-Token corresponding to iToken
     * @return interestReward P-Token reward
     * @return stakeNftIds Staked nft ids
     * @return depositNftIds Deposited nft ids
     */
    function getUserInfo(address userAddr, address nftAsset) external returns (
        uint256 collectRate,
        uint256 iTokenAmount,
        uint256 pTokenAmount,
        uint256 interestReward,
        uint256[] memory stakeNftIds,
        uint256[] memory depositNftIds
    ) {
        UserInfo storage userInfo = _userInfo[userAddr];
        collectRate = userInfo.collectRate;

        uint256 poolId = _nftInfo[nftAsset].poolId;
        iTokenAmount = userInfo.iTokenAmount[poolId];

        (address iTokenAddr, , uint256 pieceCount, , ) = INftGateway(nftGateway).marketInfo(nftAsset);
        pTokenAmount = ITokenLending(iTokenAddr).exchangeRateCurrent() * iTokenAmount / BASE_PERCENTS;

        uint256 length = userInfo.stakeIds[poolId].length();
        stakeNftIds = new uint256[](length);
        for(uint256 i = 0; i < length; i++) {
            stakeNftIds[i] = userInfo.stakeIds[poolId].at(i);
        }

        length = userInfo.depositIds[poolId].length();
        depositNftIds = new uint256[](length);
        for(uint256 i = 0; i < length; i++) {
            depositNftIds[i] = userInfo.depositIds[poolId].at(i);
        }

        uint256 amount = length * pieceCount;
        interestReward = pTokenAmount > amount ? pTokenAmount - amount : 0;
    }

    /**
     * @notice Get staked nft id info
     * @param poolId Pool ID
     * @param nftId nft id
     * @return uint256 Deposited amount + unclaimed rewards
     * @return uint256 Deposited amount
     * @return uint256 Unclaimed rewards
     */
    function getStakeInfo(uint256 poolId, uint256 nftId) public view returns (uint256, uint256, uint256) {
        IApeCoinStaking apeCoinStakingContract = IApeCoinStaking(apeCoinStaking);
        (uint256 stakingAmount, ) = apeCoinStakingContract.nftPosition(poolId, nftId);
        uint256 pendingRewards = apeCoinStakingContract.pendingRewards(poolId, address(0), nftId);
        return (stakingAmount + pendingRewards, stakingAmount, pendingRewards);
    }

    /**
     * @notice Get reward rate per block
     * @param poolId pool id
     * @param addAmount Addd staked amount
     * @return uint256 Reward rate per block
     */
    function getRewardRatePerBlock(uint256 poolId, uint256 addAmount) public view returns (uint256) {
        IApeCoinStaking apeCoinStakingContract = IApeCoinStaking(apeCoinStaking);
        ( , uint256 lastRewardsRangeIndex, uint256 stakedAmount, ) = apeCoinStakingContract.pools(poolId);
        stakedAmount += addAmount;
        stakedAmount = stakedAmount == 0 ? 1 : stakedAmount;
        IApeCoinStaking.TimeRange memory timeRange = apeCoinStakingContract.getTimeRangeBy(poolId, lastRewardsRangeIndex);
        // 8760 = 24 * 365
        return (uint256(timeRange.rewardsPerHour) * 8760 * BASE_PERCENTS) / (stakedAmount * BLOCKS_PER_YEAR);
    }
    
    /**
     * @notice Get user's rewards and borrowing interest per block
     * @param userAddr User address
     * @return totalIncome Rewards per block
     * @return totalPay Borrowing interest per block
     */
    function getUserHealth(address userAddr) public returns (uint256 totalIncome, uint256 totalPay) {
        UserInfo storage userInfo = _userInfo[userAddr];
        
        for(uint256 poolId = BAYC_POOL_ID; poolId <= BAKC_POOL_ID; poolId++) {
            uint256 poolStakingRatePerBlock = getRewardRatePerBlock(poolId, 0);
            totalIncome += userInfo.stakeAmount[poolId] * poolStakingRatePerBlock / BASE_PERCENTS;
        }
        uint256 borrowRate = IApePool(apePool).borrowRatePerBlock();
        uint256 borrowedAmount = IApePool(apePool).borrowBalanceCurrent(userAddr);
        totalPay = borrowedAmount * borrowRate / BASE_PERCENTS;
    }

    /**
     * @notice Get agency address of NFT staking
     * @param nftAsset nft asset address
     * @return address Agency address of staking
     */
    function _getPTokenStaking(address nftAsset) internal view returns (address) {
        require(nftAsset == BAYC_ADDR || nftAsset == MAYC_ADDR);
        return nftAsset == BAYC_ADDR ? pbaycAddr : pmaycAddr;
    }

    /**
     * @notice Delete user deposit information
     * @param userAddr User address
     * @param nftAsset nft asset address
     * @param nftId nft id
     * @return iTokenAmount iToken amount
     */
    function _delUserDepositInfo(address userAddr, address nftAsset, uint256 nftId) internal returns (uint256 iTokenAmount){
        NftInfo storage nftInfo = _nftInfo[nftAsset];
        iTokenAmount = nftInfo.iTokenAmount[nftId];
        delete nftInfo.depositor[nftId];
        delete nftInfo.iTokenAmount[nftId];

        UserInfo storage userInfo = _userInfo[userAddr];
        userInfo.depositIds[nftInfo.poolId].remove(nftId);
        userInfo.iTokenAmount[nftInfo.poolId] -= iTokenAmount;
    }

    /**
     * @notice Withdraw NFT from lending market
     * @param userAddr User address
     * @param nftAsset nft asset address
     * @param nftId nft id
     */
    function _withdrawNftFromLending(address userAddr, address nftAsset, uint256 nftId) internal {
        uint256 iTokenAmount = _delUserDepositInfo(userAddr, nftAsset, nftId);
        (address iTokenAddr, address pTokenAddr, uint256 pieceCount, , ) = INftGateway(nftGateway).marketInfo(nftAsset);

        uint balanceBefore = IERC20Upgradeable(pTokenAddr).balanceOf(address(this));
        ITokenLending(iTokenAddr).redeem(iTokenAmount);
        uint balanceAfter = IERC20Upgradeable(pTokenAddr).balanceOf(address(this));
        uint256 redeemAmount = balanceAfter - balanceBefore;
        require(redeemAmount >= pieceCount,"less");

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = nftId;
        IPTokenApeStaking(pTokenAddr).withdraw(tokenIds);
        IERC721Upgradeable(nftAsset).safeTransferFrom(address(this), userAddr, nftId);
        uint256 remainingAmount = redeemAmount - pieceCount;
        _transferAsset(pTokenAddr, userAddr, remainingAmount);
        emit WithdrawNftFromStake(userAddr, nftAsset, nftId, redeemAmount, pieceCount);
    }

    function _approveMax(address tokenAddr, address spender, uint256 amount) internal {
        IERC20Upgradeable token = IERC20Upgradeable(tokenAddr);
        uint256 allowance = token.allowance(address(this), spender);
        if(allowance < amount) {
            token.safeApprove(spender, 0);
            token.safeApprove(spender, type(uint256).max);
        }
    }

    /**
     * @notice Supply NFT to lending market
     * @param userAddr User address
     * @param nftAsset nft asset address
     * @param nftIds nft ids
     */
    function _depositNftToLending(address userAddr, address nftAsset, uint256[] memory nftIds) internal {
        uint length = nftIds.length;
        if(length > 0) {
            NftInfo storage nftInfo = _nftInfo[nftAsset];
            UserInfo storage userInfo = _userInfo[userAddr];

            (address iTokenAddr, address pTokenAddr, , , ) = INftGateway(nftGateway).marketInfo(nftAsset);
            for(uint256 i = 0; i < length; i++) {
                uint256 nftId = nftIds[i];
                IERC721Upgradeable(nftAsset).safeTransferFrom(userAddr, address(this), nftId);
                userInfo.depositIds[nftInfo.poolId].add(nftId);
                nftInfo.depositor[nftId] = userAddr;
            }
            
            uint256 tokenAmount = IPTokenApeStaking(pTokenAddr).deposit(nftIds, type(uint256).max);
            _approveMax(pTokenAddr, iTokenAddr, tokenAmount);

            uint256 iTokenBalanceBefore = IERC20Upgradeable(iTokenAddr).balanceOf(address(this));
            ITokenLending(iTokenAddr).mint(tokenAmount);
            uint256 iTokenBalanceAfter = IERC20Upgradeable(iTokenAddr).balanceOf(address(this));

            uint256 amount = iTokenBalanceAfter - iTokenBalanceBefore;
            uint256 singleQuantity = amount / length;
            for(uint i = 0; i < length; i++) {
                nftInfo.iTokenAmount[nftIds[i]] = singleQuantity;
            }
            userInfo.iTokenAmount[nftInfo.poolId] += amount;

            emit DepositNftToStake(userAddr, nftAsset, nftIds, amount, tokenAmount);
        }
    }

    function _storeUserInfo(
        address userAddr,
        address nftAsset,
        IApeCoinStaking.SingleNft[] memory _nfts,
        IApeCoinStaking.PairNftDepositWithAmount[] memory _nftPairs
    ) internal returns (uint256, uint256) {
        NftInfo storage nftInfo = _nftInfo[nftAsset];
        UserInfo storage userInfo = _userInfo[userAddr];

        address ptokenStaking = _getPTokenStaking(nftAsset);

        uint256 amount;
        uint256 tokenId;

        uint256 nftAmount = 0;
        for (uint256 index = 0; index < _nfts.length; index++) {
            tokenId = _nfts[index].tokenId;
            _store(userAddr, ptokenStaking, nftAsset, tokenId);
            amount = _nfts[index].amount;
            nftAmount += amount;
            
            emit StakeSingleNft(userAddr, nftAsset, tokenId, amount);
        }
        userInfo.stakeAmount[nftInfo.poolId] += nftAmount;

        uint256 nftPairAmount = 0;
        for (uint256 index = 0; index < _nftPairs.length; index++) {
            tokenId = _nftPairs[index].bakcTokenId;
            require(_validOwner(userAddr, ptokenStaking, nftAsset, _nftPairs[index].mainTokenId),"main");
            _store(userAddr, pbakcAddr, BAKC_ADDR, tokenId);
            amount =_nftPairs[index].amount;
            nftPairAmount += amount;
            emit StakePairNft(userAddr, nftAsset, _nftPairs[index].mainTokenId, tokenId, amount);
        }
        userInfo.stakeAmount[_nftInfo[BAKC_ADDR].poolId] += nftPairAmount;
        return (nftAmount, nftPairAmount);
    }

    function _store(address userAddr, address ptokenStaking, address nftAsset, uint256 nftId) internal {
        require(_validOwner(userAddr, ptokenStaking, nftAsset, nftId),"owner");
        NftInfo storage nftInfo = _nftInfo[nftAsset];
        
        if(nftInfo.staker[nftId] == address(0)) {
            nftInfo.staker[nftId] = userAddr;
            nftInfo.stakeIds.add(nftId);

            UserInfo storage userInfo = _userInfo[userAddr];
            userInfo.stakeIds[nftInfo.poolId].add(nftId);

            (uint256 stakingAmount, ) = IApeCoinStaking(apeCoinStaking).nftPosition(nftInfo.poolId, nftId);
            userInfo.stakeAmount[nftInfo.poolId] += stakingAmount;
        }
    }

    /**
     * @notice Supply and stake NFT
     * @param depositInfo NFT supplying info
     * @param stakingInfo NFT staking info
     * @param _nfts List of single NFT staking
     * @param _nftPairs List of paired NFT staking
     */
    function depositAndBorrowApeAndStake(
        DepositInfo memory depositInfo,
        StakingInfo memory stakingInfo,
        IApeCoinStaking.SingleNft[] calldata _nfts,
        IApeCoinStaking.PairNftDepositWithAmount[] calldata _nftPairs
    ) external nonReentrant {
        address userAddr = msg.sender;
        address ptokenStaking = _getPTokenStaking(stakingInfo.nftAsset);

        // 1, handle borrow part and send ape to ptokenAddress
        if(stakingInfo.borrowAmount > 0) {
            uint256 borrowRate = IApePool(apePool).borrowRatePerBlock();
            uint256 stakingRate = getRewardRatePerBlock(_nftInfo[stakingInfo.nftAsset].poolId, stakingInfo.borrowAmount);
            require(borrowRate + stakingConfiguration.addMinStakingRate < stakingRate,"rate");
            IApePool(apePool).borrowBehalf(userAddr, stakingInfo.borrowAmount);
            IERC20Upgradeable(apeCoin).safeTransfer(ptokenStaking, stakingInfo.borrowAmount);
        }

        // 2, send cash part to ptokenAddress
        if(stakingInfo.cashAmount > 0) {
            IERC20Upgradeable(apeCoin).safeTransferFrom(userAddr, ptokenStaking, stakingInfo.cashAmount);
        }

        _depositNftToLending(userAddr, stakingInfo.nftAsset, depositInfo.mainTokenIds);
        _depositNftToLending(userAddr, BAKC_ADDR, depositInfo.bakcTokenIds);

        (uint256 nftAmount, uint256 nftPairAmount) = _storeUserInfo(userAddr, stakingInfo.nftAsset, _nfts, _nftPairs);

        // 3, deposit bayc or mayc pool
        if(_nfts.length > 0) {
            IPTokenApeStaking(ptokenStaking).depositApeCoin(nftAmount, _nfts);
        }

        // 4, deposit bakc pool
        if(_nftPairs.length > 0) {
            IPTokenApeStaking(ptokenStaking).depositBAKC(nftPairAmount, _nftPairs);
        }
    }

    /**
     * @notice Verify NFT owner
     * @param userAddr User address
     * @param ptokenStaking Address of NFT staking agency
     * @param nftAsset nft asset address
     * @param nftId nft id
     * @return bool true：Verification pass false：Verification fail
     */
    function _validOwner(address userAddr, address ptokenStaking, address nftAsset, uint256 nftId) internal view returns (bool) {
        address holder = _nftInfo[nftAsset].depositor[nftId];
        if(holder == address(0)) {
            address nftOwner = IPTokenApeStaking(ptokenStaking).getNftOwner(nftId);
            holder = INftGateway(nftOwner).nftOwner(userAddr, nftAsset, nftId);
        }
        return holder == userAddr;
    }

    /**
     * @notice Claim ApeCoins for single NFT staking
     * @param nftAsset nft asset address
     * @param _nfts Claim ApeCoins for single NFT staking
     */
    function withdrawApeCoin(address nftAsset, IApeCoinStaking.SingleNft[] calldata _nfts, IApeCoinStaking.PairNftWithdrawWithAmount[] calldata _nftPairs) external nonReentrant {
        _withdrawApeCoin(msg.sender, nftAsset, _nfts, _nftPairs, RewardAction.WITHDRAW);
    }

    /**
     * @notice Verify NFT staker
     * @param userAddr User address
     * @param ptokenStaking Address of NFT staking agency
     * @param nftAsset nft asset address
     * @param nftId nft id
     * @param actionType Event type
     * @return RewardAction Event type
     */
    function _validStaker(address userAddr, address ptokenStaking, address nftAsset, uint256 nftId, RewardAction actionType) internal view returns (RewardAction) {
        address staker = _nftInfo[nftAsset].staker[nftId];
        require(staker == userAddr,"staker");
        if(!_validOwner(userAddr, ptokenStaking, nftAsset, nftId) && actionType == RewardAction.WITHDRAW){
            return RewardAction.REDEEM;
        }
        return actionType;
    }

    function _removeUserInfo(address nftAsset, uint256 nftId, uint withdrawAmount, bool maximum) internal returns (uint256, uint256) {
        NftInfo storage nftInfo = _nftInfo[nftAsset];
        uint256 poolId = nftInfo.poolId;
        ( , uint256 stakingAmount, uint256 claimAmount) = getStakeInfo(poolId, nftId);
        withdrawAmount = maximum ? stakingAmount : withdrawAmount;
        require(stakingAmount >= withdrawAmount,"more");

        UserInfo storage userInfo = _userInfo[nftInfo.staker[nftId]];
        if(withdrawAmount == stakingAmount) {
            
            delete nftInfo.staker[nftId];
            nftInfo.stakeIds.remove(nftId);
            userInfo.stakeIds[poolId].remove(nftId);
            
        } else {
            claimAmount = 0;
        }
        userInfo.stakeAmount[poolId] -= withdrawAmount;
        return (withdrawAmount, claimAmount);
    }

    function _withdrawApeCoin(
        address userAddr,
        address nftAsset,
        IApeCoinStaking.SingleNft[] memory _nfts,
        IApeCoinStaking.PairNftWithdrawWithAmount[] memory _nftPairs,
        RewardAction actionType
    ) internal {
        address ptokenStaking = _getPTokenStaking(nftAsset);
        uint256 totalWithdrawAmount = 0;
        uint256 totalClaimAmount = 0;


        // 1, check nfts owner
        for (uint256 index = 0; index < _nfts.length; index++) {
            actionType = _validStaker(userAddr, ptokenStaking, nftAsset, _nfts[index].tokenId, actionType);
            (uint256 withdrawAmount, uint256 claimAmount) = _removeUserInfo(nftAsset, _nfts[index].tokenId, _nfts[index].amount, false);
            totalWithdrawAmount += withdrawAmount;
            totalClaimAmount += claimAmount;
            emit UnstakeSingleNft(userAddr, nftAsset, _nfts[index].tokenId, _nfts[index].amount, claimAmount);
        }

        for (uint256 index = 0; index < _nftPairs.length; index++) {
            actionType = _validStaker(userAddr, pbakcAddr, BAKC_ADDR, _nftPairs[index].bakcTokenId, actionType);
            (uint256 withdrawAmount, uint256 claimAmount) = _removeUserInfo(BAKC_ADDR, _nftPairs[index].bakcTokenId, _nftPairs[index].amount, _nftPairs[index].isUncommit);
            totalWithdrawAmount += withdrawAmount;
            totalClaimAmount += claimAmount;
            emit UnstakePairNft(userAddr, nftAsset, _nftPairs[index].mainTokenId, _nftPairs[index].bakcTokenId, _nftPairs[index].amount, claimAmount);
        }

        // 2, claim rewards
        if(_nfts.length > 0) {
            IPTokenApeStaking(ptokenStaking).withdrawApeCoin(_nfts, address(this));
        }
        if(_nftPairs.length > 0) {
            IPTokenApeStaking(ptokenStaking).withdrawBAKC(_nftPairs, address(this));
        }

        // 3, repay if borrowed and mint and claim
        _repayAndClaim(userAddr, totalWithdrawAmount, totalClaimAmount, actionType);
    }

    /**
     * @notice Claiming staking rewards for a single NFT
     * @param nftAsset nft asset address
     * @param _nfts Array of NFTs staked
     */
    function claimApeCoin(address nftAsset, uint256[] calldata _nfts, IApeCoinStaking.PairNft[] calldata _nftPairs) external nonReentrant {
        _claimApeCoin(msg.sender, nftAsset, _nfts, _nftPairs, RewardAction.CLAIM);
    }

    function _claimVerify(address userAddr, address ptokenStaking, address nftAsset, uint256 nftId) internal view returns (uint256 claimAmount) {
        require(_validOwner(userAddr, ptokenStaking, nftAsset, nftId),"owner");
        ( , , claimAmount) = getStakeInfo(_nftInfo[nftAsset].poolId, nftId);
        require(claimAmount > 0,"claim");
    }

    function _claimApeCoin(
        address userAddr,
        address nftAsset,
        uint256[] calldata nftIds,
        IApeCoinStaking.PairNft[] calldata _nftPairs,
        RewardAction actionType
    ) internal {
        address ptokenStaking = _getPTokenStaking(nftAsset);
        uint256 totalClaimAmount = 0;

        uint256 claimAmount;
        uint256 tokenId;
        // 1, check nfts owner
        for (uint256 index = 0; index < nftIds.length; index++) {
            tokenId = nftIds[index];
            claimAmount = _claimVerify(userAddr, ptokenStaking, nftAsset, tokenId);
            totalClaimAmount += claimAmount;
            emit ClaimSingleNft(userAddr, nftAsset, tokenId, claimAmount);
        }

        for (uint256 index = 0; index < _nftPairs.length; index++) {
            require(_validOwner(userAddr, ptokenStaking, nftAsset, _nftPairs[index].mainTokenId),"main");
            tokenId = _nftPairs[index].bakcTokenId;
            claimAmount = _claimVerify(userAddr, pbakcAddr, BAKC_ADDR, tokenId);
            totalClaimAmount += claimAmount;
            emit ClaimPairNft(userAddr, nftAsset, _nftPairs[index].mainTokenId, tokenId, claimAmount);
        }

        // 2, claim rewards
        if(nftIds.length > 0) {
            IPTokenApeStaking(ptokenStaking).claimApeCoin(nftIds, address(this));
        }
        if(_nftPairs.length > 0) {
            IPTokenApeStaking(ptokenStaking).claimBAKC(_nftPairs, address(this));
        }

        // 3, repay if borrowed and mint and claim
        _repayAndClaim(userAddr, 0, totalClaimAmount, actionType);
    }

    /**
     * @notice Repay and reinvest
     * @param userAddr User address
     * @param allAmount Deposit amount
     * @param allClaimAmount Reward amount
     * @param actionType Event type
     */
    function _repayAndClaim(address userAddr, uint256 allAmount, uint256 allClaimAmount, RewardAction actionType) internal {
        uint256 fee = allClaimAmount * stakingConfiguration.feeRate / BASE_PERCENTS;
        allClaimAmount -= fee;
        _transferAsset(apeCoin, feeTo, fee);

        uint256 totalAmount = allAmount + allClaimAmount;
        _approveMax(address(apeCoin), apePool, totalAmount);

        // 1, repay if borrowed
        uint256 repayed = IApePool(apePool).borrowBalanceCurrent(userAddr);

        if(repayed > 0) {
            if(allAmount < repayed) {
                repayed -= allAmount;
                allAmount = 0;
                if(allClaimAmount < repayed) {
                    allClaimAmount = 0;
                } else {
                    allClaimAmount -= repayed;
                }
            } else {
                allAmount -= repayed;
            }
            IApePool(apePool).repayBorrowBehalf(userAddr, totalAmount - (allAmount + allClaimAmount));
        }

        totalAmount = allAmount + allClaimAmount;
        if(totalAmount > 0) {
            if(actionType == RewardAction.REDEEM || actionType == RewardAction.ONREDEEM) {//only return staking amount
                // transfer left Ape to user
                _transferAsset(apeCoin, userAddr, allAmount);
                // transfer left claim Ape to feeTo
                _transferAsset(apeCoin, feeTo, allClaimAmount);
            } else {
                uint256 claimAmount = totalAmount * _userInfo[userAddr].collectRate / BASE_PERCENTS;
                _transferAsset(apeCoin, userAddr, claimAmount);
                if(totalAmount > claimAmount) {
                    uint256 mintAmount = totalAmount - claimAmount;
                    IApePool(apePool).mintBehalf(userAddr, mintAmount);
                }            
            }
        }
    }

    function _transferAsset(address token, address to, uint256 amount) internal {
        if(amount > 0) {
            IERC20Upgradeable(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Reward reinvestment
     * @param userAddr User address
     * @param baycNfts bayc nft ids
     * @param maycNfts mayc nft ids
     * @param baycPairNfts List of bayc-bakc pair
     * @param maycPairNfts List of mayc-bakc pair
     */
    function claimAndRestake(
        address userAddr,
        uint256[] calldata baycNfts,
        uint256[] calldata maycNfts,
        IApeCoinStaking.PairNft[] calldata baycPairNfts,
        IApeCoinStaking.PairNft[] calldata maycPairNfts
    ) external nonReentrant {
        require(msg.sender == userAddr || hasRole(REINVEST_ROLE, msg.sender));
        _claimApeCoin(userAddr, BAYC_ADDR, baycNfts, baycPairNfts, RewardAction.RESTAKE);
        _claimApeCoin(userAddr, MAYC_ADDR, maycNfts, maycPairNfts, RewardAction.RESTAKE);
    }

    /**
     * @notice Suspend staking for users with high health factor
     * @param userAddr User address
     * @param nftAssets Array of NFT address
     * @param nftIds nft ids
     */
    function unstakeAndRepay(address userAddr, address[] calldata nftAssets, uint256[] calldata nftIds) external nonReentrant {
        require(nftAssets.length == nftIds.length);
        uint256 totalIncome;
        uint256 totalPay;
        (totalIncome, totalPay) = getUserHealth(userAddr);
        require(totalIncome * BASE_PERCENTS < totalPay * stakingConfiguration.liquidateRate,"income");
        for(uint256 i = 0; i < nftAssets.length; i++) {
            require(userAddr == _nftInfo[nftAssets[i]].staker[nftIds[i]],"staker");
            _onStopStake(nftAssets[i], nftIds[i], RewardAction.STOPSTAKE);
            (totalIncome, totalPay) = getUserHealth(userAddr);
            if(totalIncome * BASE_PERCENTS >= totalPay * stakingConfiguration.borrowSafeRate) {
                _transferAsset(pawnToken, msg.sender, stakingConfiguration.liquidatePawnAmount);           
                break;
            }
        }
    }

    /**
     * @notice NFT can be withdrawn after withdrawing all staked ApeCoins
     * @param baycTokenIds bayc nft ids
     * @param maycTokenIds mayc nft ids
     * @param bakcTokenIds bakc nft ids
     */
    function withdraw(
        uint256[] calldata baycTokenIds,
        uint256[] calldata maycTokenIds,
        uint256[] calldata bakcTokenIds
    ) external nonReentrant {
        address userAddr = msg.sender;
        for(uint256 i = 0; i < baycTokenIds.length; i++) {
            _withdraw(userAddr, BAYC_ADDR, baycTokenIds[i], false);
        }
        for(uint256 i = 0; i < maycTokenIds.length; i++) {
            _withdraw(userAddr, MAYC_ADDR, maycTokenIds[i], false);
        }      
        for(uint256 i = 0; i < bakcTokenIds.length; i++) {
            _withdraw(userAddr, BAKC_ADDR, bakcTokenIds[i], true);
        }
    }

    /**
     * @notice Withdraw single staked NFT
     * @param userAddr User address
     * @param nftAsset nft asset address
     * @param nftId nft id
     * @param paired Whether to pair
     */
    function _withdraw(address userAddr, address nftAsset, uint256 nftId, bool paired) internal {
        NftInfo storage nftInfo = _nftInfo[nftAsset];
        require(userAddr == nftInfo.depositor[nftId],"depositor");
        require(nftInfo.staker[nftId] == address(0),"staker");

        if(!paired) {
            (uint256 tokenId,bool isPaired) = IApeCoinStaking(apeCoinStaking).mainToBakc(nftInfo.poolId, nftId);
            if(isPaired){
                require(_nftInfo[BAKC_ADDR].staker[tokenId] == address(0),"pair");
            }
        }
        _withdrawNftFromLending(userAddr, nftAsset, nftId);
    }

    /**
     * @notice Suspend staking due to third-party reasons
     * @param caller Caller
     * @param nftAsset nft asset address
     * @param nftIds nft ids
     * @param actionType Event type
     */
    function onStopStake(address caller, address nftAsset, uint256[] calldata nftIds, RewardAction actionType) external{
        require(msg.sender == pbaycAddr || msg.sender == pmaycAddr || msg.sender == pbakcAddr);
        if(caller != address(this)) {
            for(uint i = 0; i < nftIds.length; i++) {
                _onStopStake(nftAsset, nftIds[i], actionType);
            }
        }
    }

    struct PairVars {
        address nftAsset;
        bool isPaired;
        uint256 mainTokenId;
        uint256 bakcTokenId;
    }

    /**
     * @notice Suspend staking due to third-party reasons
     * @param nftAsset nft asset address
     * @param nftId nft id
     * @param actionType Event type
     */
    function _onStopStake(address nftAsset, uint256 nftId, RewardAction actionType) private {
        NftInfo storage nftInfo = _nftInfo[nftAsset];
        IApeCoinStaking.SingleNft[] memory _nfts;
        PairVars memory pairVars;

        address userAddr = nftInfo.staker[nftId];
        if(nftAsset == BAYC_ADDR || nftAsset == MAYC_ADDR) {
            pairVars.nftAsset = nftAsset;
            pairVars.mainTokenId = nftId;
            ( , uint256 stakingAmount, ) = getStakeInfo(nftInfo.poolId, nftId);
            (pairVars.bakcTokenId, pairVars.isPaired) = IApeCoinStaking(apeCoinStaking).mainToBakc(nftInfo.poolId, nftId);
            
            if(stakingAmount > 0 && userAddr != address(0)) {
                _nfts = new IApeCoinStaking.SingleNft[](1);
                _nfts[0] = IApeCoinStaking.SingleNft({
                    tokenId: uint32(nftId),
                    amount: uint224(stakingAmount)
                });
            }
        } else if(nftAsset == BAKC_ADDR) {
            pairVars.nftAsset = BAYC_ADDR;
            pairVars.bakcTokenId = nftId;
            (pairVars.mainTokenId, pairVars.isPaired) = IApeCoinStaking(apeCoinStaking).bakcToMain(nftId, _nftInfo[pairVars.nftAsset].poolId);
            if(!pairVars.isPaired) {
                pairVars.nftAsset = MAYC_ADDR;
                (pairVars.mainTokenId, pairVars.isPaired) = IApeCoinStaking(apeCoinStaking).bakcToMain(nftId, _nftInfo[pairVars.nftAsset].poolId);
            }
        }
        
        _onStopStakePairNft(userAddr, pairVars, _nfts, actionType);
    }

    function _onStopStakePairNft(address mainUserAddr, PairVars memory pairVars, IApeCoinStaking.SingleNft[] memory _nfts, RewardAction actionType) internal {
        IApeCoinStaking.PairNftWithdrawWithAmount[] memory _nftPairs;
        address bakcUserAddr = _nftInfo[BAKC_ADDR].staker[pairVars.bakcTokenId];
        if(pairVars.isPaired) {
            ( , uint256 stakingAmount, ) = getStakeInfo(_nftInfo[BAKC_ADDR].poolId, pairVars.bakcTokenId);
            if(stakingAmount > 0 && bakcUserAddr != address(0)) {
                _nftPairs = new IApeCoinStaking.PairNftWithdrawWithAmount[](1);
                _nftPairs[0] = IApeCoinStaking.PairNftWithdrawWithAmount({
                    mainTokenId: uint32(pairVars.mainTokenId),
                    bakcTokenId: uint32(pairVars.bakcTokenId),
                    amount: uint184(stakingAmount),
                    isUncommit: true
                });
            }
            
        }
        if(_nfts.length > 0 || _nftPairs.length > 0) {
            address userAddr = mainUserAddr != address(0) ? mainUserAddr : bakcUserAddr;
            _withdrawApeCoin(userAddr, pairVars.nftAsset, _nfts, _nftPairs, actionType);
        }
    }

    /**
     * @notice Set collect rate
     * @param newCollectRate Collect rate
     */
    function setCollectRate(uint256 newCollectRate) external {
        require(newCollectRate <= BASE_PERCENTS);
        _userInfo[msg.sender].collectRate = newCollectRate;
        emit SetCollectRate(msg.sender, newCollectRate);
    }

    /**
     * @notice Set fee address
     * @param newFeeTo Fee address
     */
    function setFeeTo(address newFeeTo) external onlyRole(DEFAULT_ADMIN_ROLE) {
        feeTo = newFeeTo;
    }

    /**
     * @notice Set contract configuration info
     * @param newStakingConfiguration New configuration info
     */
    function setStakingConfiguration(StakingConfiguration memory newStakingConfiguration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingConfiguration = newStakingConfiguration;
    }
}