// SPDX-License-Identifier: MIT
// slither-disable-next-line solc-version
pragma solidity ^0.8.0;

/// @notice Permission IDs for `JBPermissions`, used throughout the Bananapus ecosystem. See
/// [`JBPermissions`](https://github.com/Bananapus/nana-core/blob/main/src/JBPermissions.sol)
/// @dev `JBPermissions` allows one address to grant another address permission to call functions in Juicebox contracts
/// on their behalf. Each ID in `JBPermissionIds` grants access to a specific set of these functions.
library JBPermissionIds {
    uint8 internal constant ROOT = 1; // All permissions across every contract. Very dangerous. BE CAREFUL!

    /* Used by `nana-core`: https://github.com/Bananapus/nana-core */
    uint8 internal constant QUEUE_RULESETS = 2; // Permission to call `JBController.queueRulesetsOf` and
        // `JBController.launchRulesetsFor`.
    uint8 internal constant CASH_OUT_TOKENS = 3; // Permission to call `JBMultiTerminal.cashOutTokensOf`.
    uint8 internal constant SEND_PAYOUTS = 4; // Permission to call `JBMultiTerminal.sendPayoutsOf`.
    uint8 internal constant MIGRATE_TERMINAL = 5; // Permission to call `JBMultiTerminal.migrateBalanceOf`.
    uint8 internal constant SET_PROJECT_URI = 6; // Permission to call `JBController.setUriOf`.
    uint8 internal constant DEPLOY_ERC20 = 7; // Permission to call `JBController.deployERC20For`.
    uint8 internal constant SET_TOKEN = 8; // Permission to call `JBController.setTokenFor`.
    uint8 internal constant MINT_TOKENS = 9; // Permission to call `JBController.mintTokensOf`.
    uint8 internal constant BURN_TOKENS = 10; // Permission to call `JBController.burnTokensOf`.
    uint8 internal constant CLAIM_TOKENS = 11; // Permission to call `JBController.claimTokensFor`.
    uint8 internal constant TRANSFER_CREDITS = 12; // Permission to call `JBController.transferCreditsFrom`.
    uint8 internal constant SET_CONTROLLER = 13; // Permission to call `JBDirectory.setControllerOf`.
    uint8 internal constant SET_TERMINALS = 14; // Permission to call `JBDirectory.setTerminalsOf`.
    // Be careful - `SET_TERMINALS` can be used to remove the primary terminal.
    uint8 internal constant SET_PRIMARY_TERMINAL = 15; // Permission to call `JBDirectory.setPrimaryTerminalOf`.
    uint8 internal constant USE_ALLOWANCE = 16; // Permission to call `JBMultiTerminal.useAllowanceOf`.
    uint8 internal constant SET_SPLIT_GROUPS = 17; // Permission to call `JBController.setSplitGroupsOf`.
    uint8 internal constant ADD_PRICE_FEED = 18; // Permission to call `JBPrices.addPriceFeedFor`.
    uint8 internal constant ADD_ACCOUNTING_CONTEXTS = 19; // Permission to call
        // `JBMultiTerminal.addAccountingContextsFor`.

    /* Used by `nana-721-hook`: https://github.com/Bananapus/nana-721-hook */
    uint8 internal constant ADJUST_721_TIERS = 20; // Permission to call `JB721TiersHook.adjustTiers`.
    uint8 internal constant SET_721_METADATA = 21; // Permission to call `JB721TiersHook.setMetadata`.
    uint8 internal constant MINT_721 = 22; // Permission to call `JB721TiersHook.mintFor`.
    uint8 internal constant SET_721_DISCOUNT_PERCENT = 23; // Permission to call `JB721TiersHook.setDiscountPercentOf`.

    /* Used by `nana-buyback-hook`: https://github.com/Bananapus/nana-buyback-hook */
    uint8 internal constant SET_BUYBACK_TWAP = 24; // Permission to call `JBBuybackHook.setTwapWindowOf` and
        // `JBBuybackHook.setTwapSlippageToleranceOf`.
    uint8 internal constant SET_BUYBACK_POOL = 25; // Permission to call `JBBuybackHook.setPoolFor`.

    /* Used by `nana-swap-terminal`: https://github.com/Bananapus/nana-swap-terminal */
    uint8 internal constant ADD_SWAP_TERMINAL_POOL = 26; // Permission to call `JBSwapTerminal.addDefaultPool`.
    uint8 internal constant ADD_SWAP_TERMINAL_TWAP_PARAMS = 27; // Permission to call
        // `JBSwapTerminal.addTwapParamsFor`.

    /* Used by `nana-suckers`: https://github.com/Bananapus/nana-suckers */
    uint8 internal constant MAP_SUCKER_TOKEN = 28; // Permission to call `BPSucker.mapToken`.
    uint8 internal constant DEPLOY_SUCKERS = 29; // Permission to call `BPSuckerRegistry.deploySuckersFor`.
    uint8 internal constant SUCKER_SAFETY = 30; // Permission to call `BPSucker.enableEmergencyHatchFor` and
        // `BPSucker.setDeprecation`.
}
