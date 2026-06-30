// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../interfaces/IJamBalanceManager.sol";
import "../base/Errors.sol";

library JamInteraction {

    /// @dev Data representing an interaction on the chain
    struct Data {
        bool result; // If the interaction is required to succeed
        address to;
        uint256 value;
        bytes data;
    }

    function runInteractions(Data[] calldata interactions, IJamBalanceManager balanceManager) internal returns (bool) {
        for (uint i; i < interactions.length; ++i) {
            Data calldata interaction = interactions[i];
            require(interaction.to != address(balanceManager), CallToBalanceManagerNotAllowed());
            (bool execResult,) = payable(interaction.to).call{ value: interaction.value }(interaction.data);
            if (!execResult && interaction.result) return false;
        }
        return true;
    }

    function runInteractionsM(Data[] memory interactions, IJamBalanceManager balanceManager) internal returns (bool) {
        for (uint i; i < interactions.length; ++i) {
            Data memory interaction = interactions[i];
            require(interaction.to != address(balanceManager), CallToBalanceManagerNotAllowed());
            (bool execResult,) = payable(interaction.to).call{ value: interaction.value }(interaction.data);
            if (!execResult && interaction.result) return false;
        }
        return true;
    }
}