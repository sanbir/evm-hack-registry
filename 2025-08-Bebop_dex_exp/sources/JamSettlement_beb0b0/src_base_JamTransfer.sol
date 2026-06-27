// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "./JamPartner.sol";

/// @title JamTransfer
/// @notice Functions for transferring tokens from SettlementContract
abstract contract JamTransfer is JamPartner {

    using SafeTransferLib for IERC20;

    /// @dev Check if token is approved for spender, max approve if not
    /// max approval is fine for settlement contract, because we use BalanceManager for users approvals
    /// @param token token's address
    /// @param amount transfer amount
    /// @param spender spender's address, in our case it will BebopBlend contract
    function approveToken(IERC20 token, uint256 amount, address spender) internal {
        uint256 allowance = token.allowance(address(this), spender);
        if (allowance < amount) {
            token.safeApproveWithRetry(spender, type(uint256).max);
        }
    }

    /// @dev After solver settlement, transfer tokens from this contract to receiver
    /// @param tokens tokens' addresses
    /// @param minAmounts minimum amounts from order
    /// @param amounts tokens' filled amounts
    /// @param receiver address
    /// @param transferExactAmounts if true, transfer exact amounts, otherwise transfer full tokens balance
    function transferTokensFromContract(
        address[] calldata tokens,
        uint256[] calldata minAmounts,
        uint256[] memory amounts,
        address receiver,
        uint256 partnerInfo,
        bool transferExactAmounts
    ) internal {
        for (uint i; i < tokens.length; ++i) {
            if (!transferExactAmounts) {
                amounts[i] = tokens[i] == JamOrderLib.NATIVE_TOKEN ?
                    address(this).balance : IERC20(tokens[i]).balanceOf(address(this));
            }
            if (partnerInfo != 0){
                amounts[i] -= distributeFees(partnerInfo, tokens[i], amounts[i]);
            }
            require(amounts[i] >= minAmounts[i], InvalidOutputBalance(tokens[i], minAmounts[i], amounts[i]));
            if (tokens[i] == JamOrderLib.NATIVE_TOKEN) {
                (bool sent, ) = payable(receiver).call{value: amounts[i]}("");
                require(sent, FailedToSendEth());
                emit NativeTransfer(receiver, amounts[i]);
            } else {
                IERC20(tokens[i]).safeTransfer(receiver, amounts[i]);
            }
        }
    }

    /// @dev Transfer native tokens to receiver from this contract
    /// @param receiver address
    /// @param amount amount of native tokens
    function transferNativeFromContract(address receiver, uint256 amount) public {
        (bool sent, ) = payable(receiver).call{value: amount}("");
        require(sent, FailedToSendEth());
    }

    /// @dev Calculate new amounts of tokens if solver transferred excess to contract during settleBatch
    /// @param curInd index of current order
    /// @param orders array of orders
    /// @return array of new amounts
    function calculateNewAmounts(uint256 curInd, JamOrder[] calldata orders) internal view returns (uint256[] memory) {
        JamOrder calldata curOrder = orders[curInd];
        uint256[] memory newAmounts = new uint256[](curOrder.buyTokens.length);
        for (uint i; i < curOrder.buyTokens.length; ++i) {
            uint256 fullAmount;
            for (uint j = curInd; j < orders.length; ++j) {
                for (uint k; k < orders[j].buyTokens.length; ++k) {
                    if (orders[j].buyTokens[k] == curOrder.buyTokens[i]) {
                        fullAmount += orders[j].buyAmounts[k];
                        require(
                            getTotalFeesBps(curOrder.partnerInfo) == getTotalFeesBps(orders[j].partnerInfo),
                            DifferentFeesInBatch()
                        );
                    }
                }
            }
            uint256 tokenBalance = curOrder.buyTokens[i] == JamOrderLib.NATIVE_TOKEN ?
                address(this).balance : IERC20(curOrder.buyTokens[i]).balanceOf(address(this));
            // if at least two takers buy same token, we need to divide the whole tokenBalance among them.
            // for edge case with newAmounts[i] overflow, solver shouldn't submit txs in a batch
            newAmounts[i] = tokenBalance * curOrder.buyAmounts[i] / fullAmount;
            if (newAmounts[i] < curOrder.buyAmounts[i]) {
                newAmounts[i] = curOrder.buyAmounts[i];
            }
        }
        return newAmounts;
    }
}
