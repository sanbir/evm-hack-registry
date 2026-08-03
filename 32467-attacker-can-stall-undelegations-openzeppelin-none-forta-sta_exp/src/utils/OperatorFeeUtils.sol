// SPDX-License-Identifier: UNLICENSED
// See Forta Network License: https://github.com/forta-network/forta-contracts/blob/master/LICENSE.md

pragma solidity 0.8.23;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

uint256 constant FEE_BASIS_POINTS_DENOMINATOR = 10_000;

library OperatorFeeUtils {
    using SafeERC20 for IERC20;

    function deductAndTransferFee(
        uint256 amount,
        uint256 feeInBasisPoints,
        address feeReceiver,
        IERC20 token
    )
        internal
        returns (uint256)
    {
        uint256 feeAmount = 0;
        if (feeInBasisPoints > 0) {
            feeAmount = Math.mulDiv(amount, feeInBasisPoints, FEE_BASIS_POINTS_DENOMINATOR);
            if (feeAmount > 0) {
                token.safeTransfer(feeReceiver, feeAmount);
            }
        }
        return amount - feeAmount;
    }
}
