// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: Copyright 2021-25 Panther Protocol Foundation
pragma solidity ^0.8.19;

import "./core/interfaces/IPrpVoucherController.sol";
import "./core/interfaces/IPrpConversion.sol";

import "../../common/ImmutableOwnable.sol";
import "../../common/TransferHelper.sol";
import "../../common/UtilsLib.sol";
import "../../common/Claimable.sol";
import { GT_ZKP_RELEASE } from "../../common/Constants.sol";

import "./errMsgs/ZkpReserveControllerErrMsgs.sol";

/**
 * @title ZkpReserveController
 * @notice This contract is designed to refill the PRP/ZKP Pool with $ZKP tokens.
 * @dev The contract releases the ZKP tokens linearly to the PRP/ZKP pool. User who releases the
 * ZKPs that surpasses a minimum reward threshold are rewarded with PRP tokens via the
 * PRPVoucherGrantor contract.
 */
contract ZkpReserveController is ImmutableOwnable, Claimable {
    using TransferHelper for address;
    using TransferHelper for address payable;
    using UtilsLib for uint256;
    using UtilsLib for uint64;

    uint256 public immutable START_BLOCK;
    uint256 public constant SCALE = 1e12;
    address public immutable ZKP_TOKEN;
    address public immutable PANTHER_POOL;

    uint64 private scReleasablePerBlock;
    uint64 private scMinRewardableAmount;
    uint64 private scTotalReleased;
    uint64 private scAccumulatedAccrual;

    uint32 private blockAtLastUpdate; // Will remain 0 until first updateParams call

    event ZkpReservesReleased(bytes32 saltHash, uint256 amount);
    event RewardParamsUpdated(
        uint256 releasablePerBlock,
        uint256 minRewardableAmount,
        uint256 blockAtLastUpdate
    );
    event ZkpRescued(address to, uint256 amount);

    /**
     * @notice Constructor to initialize the AMMRefill contract.
     * @param _owner The address of the contract owner.
     * @param _zkpToken The address of the ZKP token contract.
     * @param _pantherPool The address of the AMM contract to receive ZKP tokens.
     */
    constructor(
        address _owner,
        address _zkpToken,
        address _pantherPool
    ) ImmutableOwnable(_owner) {
        require(
            _zkpToken != address(0) && _pantherPool != address(0),
            ERR_INVALID_PARAMS
        );

        ZKP_TOKEN = _zkpToken;
        PANTHER_POOL = _pantherPool;
        START_BLOCK = block.number;
    }

    function getRewardStats()
        external
        view
        returns (
            uint256 _releasablePerBlock,
            uint256 _minRewardableAmount,
            uint256 _totalReleased,
            uint256 _blockAtLastUpdate,
            uint256 _scAccumulatedAccrual
        )
    {
        _releasablePerBlock = scReleasablePerBlock.scaleUpBy1e12();
        _minRewardableAmount = scMinRewardableAmount.scaleUpBy1e12();
        _totalReleased = scTotalReleased.scaleUpBy1e12();
        _blockAtLastUpdate = blockAtLastUpdate;
        _scAccumulatedAccrual = scAccumulatedAccrual.scaleUpBy1e12();
    }

    /**
     * @notice Returns the current releasable amount of ZKP tokens based on the configuration.
     * @return uint64 The amount of ZKP tokens that can currently be released.
     */
    function releasableAmount() external view returns (uint256) {
        uint256 contractBalance = ZKP_TOKEN.safeBalanceOf(address(this));
        uint256 releasable = _scReleasableAmount().scaleUpBy1e12();

        return releasable > contractBalance ? contractBalance : releasable;
    }

    /**
     * @notice Updates the configuration parameters for the AMMRefill contract.
     * @dev Can only be called by the contract owner.
     * @param releasablePerBlock The new amount of ZKP tokens that can be released per block.
     * @param minRewardedAmount The new minimum amount of ZKP tokens that need to be released to reward the user.
     */
    function updateParams(
        uint256 releasablePerBlock,
        uint256 minRewardedAmount
    ) external onlyOwner {
        uint32 currentBlock = block.number.safe32();

        if (blockAtLastUpdate == 0) {
            // First updateParams call
            blockAtLastUpdate = currentBlock;
            scAccumulatedAccrual = 0;
        } else {
            // finalize old accrual and start a new accrual period
            uint64 blockOffset = currentBlock - blockAtLastUpdate;
            uint64 scOldAccrual = scReleasablePerBlock * blockOffset;

            scAccumulatedAccrual += scOldAccrual;
            blockAtLastUpdate = currentBlock;
        }

        scReleasablePerBlock = releasablePerBlock
            .safeScaleDownBy1e12()
            .safe64();
        scMinRewardableAmount = minRewardedAmount
            .safeScaleDownBy1e12()
            .safe64();

        emit RewardParamsUpdated(
            releasablePerBlock,
            minRewardedAmount,
            blockAtLastUpdate
        );
    }

    /**
     * @notice Triggers a refill of the AMM with ZKP tokens.
     * @dev Calculates the releasable amount of tokens and sends them to the AMM.
     * If the releasable amount is above the minimal rewarded amount, the user is rewarded with PRP tokens.
     * @param saltHash A unique hash value used to distinguish between different refill actions.
     */
    function releaseZkps(bytes32 saltHash) external {
        uint256 contractBalance = ZKP_TOKEN.safeBalanceOf(address(this));
        require(contractBalance > SCALE, "no zkp is available");

        uint64 _scReleasable = _scReleasableAmount();
        uint256 _releasable = _scReleasable.scaleUpBy1e12();

        if (_releasable > contractBalance) {
            _releasable = contractBalance;
            _scReleasable = _releasable.scaleDownBy1e12().safe64();
        }

        ZKP_TOKEN.safeTransfer(PANTHER_POOL, _releasable);
        IPrpConversion(PANTHER_POOL).increaseZkpReserve();

        scTotalReleased += _scReleasable;

        if (_scReleasable >= scMinRewardableAmount) {
            IPrpVoucherController(PANTHER_POOL).generateRewards(
                saltHash,
                0,
                GT_ZKP_RELEASE
            );
        }

        emit ZkpReservesReleased(saltHash, _releasable);
    }

    /**
     * @dev Internal function to calculate the releasable amount of ZKP tokens.
     * @return uint64 The amount of ZKP tokens that can currently be released,
     * scaled by 1e12
     */
    function _scReleasableAmount() private view returns (uint64) {
        // If no updateParams call has been made yet, no accrual starts.
        if (blockAtLastUpdate == 0) {
            return 0;
        }

        uint64 currentBlock = block.number.safe64();
        uint64 blockOffset = currentBlock - blockAtLastUpdate;

        uint64 scTotalAccrued = scAccumulatedAccrual +
            (scReleasablePerBlock * blockOffset);

        if (scTotalAccrued <= scTotalReleased) {
            return 0;
        }

        return scTotalAccrued - scTotalReleased;
    }

    /**
     * @dev Allows the contract owner to rescue ZKP tokens from the contract.
     * This function is intended for use in scenarios where tokens need to be recovered
     * or reallocated. It is a safeguard to ensure that tokens can be retrieved in case
     * they are sent to the contract by mistake or need to be moved for administrative reasons.
     * @param to The address to which the ZKP tokens will be sent.
     * @param amount The amount of ZKP tokens to rescue.
     */
    function rescueZkps(address to, uint256 amount) external onlyOwner {
        _claimErc20(ZKP_TOKEN, to, amount);
        emit ZkpRescued(to, amount);
    }
}
