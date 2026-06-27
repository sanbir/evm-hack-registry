// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol" ;
import "@openzeppelin/contracts/utils/math/SafeCast.sol" ;

/**
 * @title SwapGuard
 * @notice This contract is used to limit the amount of tokens that can be lost in a single transaction
 */
contract SwapGuard {
    using SafeCast for uint256;
    using SafeCast for int256;

    error LostMoreThanAllowed(uint256, uint256);
    error BadInteractionResponse(bytes);

    struct Data {
        address target;
        uint256 value;
        bytes callData;
    }

    /// @notice Performs a series of interactions and checks that vault received at least the expected amount of tokens
    /// @param interactions Array of interactions to perform
    /// @param vault Address of the vault
    /// @param tokens Array of tokens to check
    /// @param tokenPrices Array of prices of tokens
    /// @param balanceChanges Array of expected balance changes
    /// @param allowedLoss Maximum amount of tokens that can be lost
    function envelope(
        Data[] calldata interactions,
        address vault,
        IERC20[] calldata tokens,
        uint256[] calldata tokenPrices,
        int256[] calldata balanceChanges,
        uint256 allowedLoss
    ) public payable {
        unchecked {
            // save all current balances of tokens
            uint256[] memory balancesBeforeInteractions = new uint256[](tokens.length);
            for (uint256 i = 0; i < tokens.length; i++) {
                balancesBeforeInteractions[i] = tokens[i].balanceOf(vault);
            }

            for (uint256 i = 0; i < interactions.length; i++) {
                Data memory interaction = interactions[i];
                // solhint-disable-next-line avoid-low-level-calls
                (bool success, bytes memory returnData) = interaction.target.call{value: interaction.value}(interaction.callData);
                if (!success) {
                    revert BadInteractionResponse(returnData);
                }
            }

            uint256 totalLoss = 0;
            // check that we didn't loose more than allowedLoss
            // it is okay if we got more than expected
            for (uint256 i = 0; i < tokens.length; i++) {
                uint256 balanceAfterInteraction = tokens[i].balanceOf(vault);
                int256 expectedBalanceChange = balanceChanges[i];
                int256 actualBalanceChange = balanceAfterInteraction.toInt256() - balancesBeforeInteractions[i].toInt256();
                if (actualBalanceChange < expectedBalanceChange) {
                    totalLoss += (expectedBalanceChange - actualBalanceChange).toUint256() * tokenPrices[i];
                }
                if (totalLoss > allowedLoss) {
                    revert LostMoreThanAllowed(totalLoss, allowedLoss);
                }
            }
        }
    }
}
