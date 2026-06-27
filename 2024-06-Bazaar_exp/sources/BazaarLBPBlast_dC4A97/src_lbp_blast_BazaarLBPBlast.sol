pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import {IVault} from "balancer-lbp-patch/v2-vault/contracts/interfaces/IVault.sol";
import {IERC20} from "balancer-lbp-patch/v2-solidity-utils/contracts/openzeppelin/IERC20.sol";

import {BazaarLBP} from "../BazaarLBP.sol";
import {IBlast} from "../../interfaces/blast/IBlast.sol";

/**
 * @dev An implementation of NoProtocolLiquidityBootstrappingPool defined at this commit:
 *   https://github.com/balancer/balancer-v2-monorepo/commit/2e7998283713e1df445c15e368ca30fa2ee4a725
 *
 *  1. Track total amount of swap fees accrued per pool token.
 *  2. Swaps automatically enabled right at the start time. Only can be disabled by the owner
 *  3. Disable the pause/buffer window duration. Initially there for the balancer DAO to trigger an
 *     an emergency pause if needed after deploy. We dont need this as the pool code is battle tested.
 */
contract BazaarLBPBlast is BazaarLBP {
    IBlast public BLAST;

    constructor(
        IVault vault,
        string memory name,
        string memory symbol,
        IERC20[] memory tokens,
        // Modified
        uint256[] memory startWeights,
        uint256[] memory endWeights,
        uint256 startTime,
        uint256 endTime,
        // End
        uint256 swapFeePercentage,
        IBlast _blast
    ) BazaarLBP(vault, name, symbol, tokens, startWeights, endWeights, startTime, endTime, swapFeePercentage) {
        BLAST = _blast;

        // `msg.sender` is the LBP Factory
        BLAST.configureClaimableGas();
        BLAST.configureGovernor(msg.sender);
    }
}
