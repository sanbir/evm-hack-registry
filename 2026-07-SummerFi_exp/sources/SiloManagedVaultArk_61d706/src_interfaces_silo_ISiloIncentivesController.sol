// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.28;

struct AccruedRewards {
    uint256 amount;
    bytes32 programId;
    address rewardToken;
}
interface ISiloIncentivesController {
    /**
     * @dev Claims reward for an user to the desired address, on all the assets of the lending pool,
     * accumulating the pending rewards
     * @param _to Address that will be receiving the rewards
     * @return accruedRewards
     */
    function claimRewards(
        address _to
    ) external returns (AccruedRewards[] memory accruedRewards);
}
