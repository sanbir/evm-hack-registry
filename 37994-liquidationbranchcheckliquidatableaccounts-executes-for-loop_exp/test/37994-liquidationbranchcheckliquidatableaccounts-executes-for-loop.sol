// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*//////////////////////////////////////////////////////////////////////////
    Zaros — LiquidationBranch::checkLiquidatableAccounts() executes for loop
    with wrong values, causing array-out-of-bounds revert
    (cryptedOji, Codehawks 2024-07-zaros, finding #37994)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable array-sizing and absolute-indexing lines from
    LiquidationBranch.checkLiquidatableAccounts are inlined VERBATIM. The
    Exploit populates a segment of "active" trading accounts, shows the
    lowerBound=0 segment works fine, then shows any non-zero-lowerBound
    segment containing a liquidatable account reverts with an out-of-bounds
    Panic — breaking paginated liquidation scanning entirely (no fork, no
    cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: the output array is sized to the SEGMENT WIDTH
    (`upperBound - lowerBound`), intended to be indexed 0..width-1 as
    results are found. But the loop variable `i` walks the ABSOLUTE range
    [lowerBound, upperBound) and is used directly as the array index
    (`liquidatableAccountsIds[i] = tradingAccountId`) instead of the
    relative offset (`i - lowerBound`). The moment `lowerBound != 0` and a
    liquidatable account is found, `i` is already >= the array's length
    (`upperBound - lowerBound`), and the write reverts with an array
    out-of-bounds Panic(0x32) — this method is explicitly meant to support
    segmented/paginated checking (per its own NatSpec), but segmentation
    with any non-zero lowerBound is completely broken.
//////////////////////////////////////////////////////////////*/

/// @notice Reduced LiquidationBranch. Tracks a list of "active" trading
///         account ids and which of them are currently liquidatable, then
///         exposes the same paginated scan the real keeper integration
///         (LiquidationKeeper.checkUpkeep) relies on.
contract LiquidationBranch {
    uint128[] public activeAccountIds;
    mapping(uint256 => bool) public isLiquidatableAtIndex;

    function addActiveAccount(uint128 accountId, bool liquidatable) external {
        activeAccountIds.push(accountId);
        isLiquidatableAtIndex[activeAccountIds.length - 1] = liquidatable;
    }

    /// @param lowerBound The lower bound of the accounts to check
    /// @param upperBound The upper bound of the accounts to check
    function checkLiquidatableAccounts(
        uint256 lowerBound,
        uint256 upperBound
    )
        external
        view
        returns (uint128[] memory liquidatableAccountsIds)
    {
        // prepare output array size
        liquidatableAccountsIds = new uint128[](upperBound - lowerBound); // @> VULN: array sized by SEGMENT WIDTH, indexed by ABSOLUTE i below

        // return if nothing to process
        if (liquidatableAccountsIds.length == 0) return liquidatableAccountsIds;

        // cache active account ids length
        uint256 cachedAccountsIdsWithActivePositionsLength = activeAccountIds.length;

        // iterate over active accounts within given bounds
        for (uint256 i = lowerBound; i < upperBound; i++) {
            // break if `i` greater then length of active account ids
            if (i >= cachedAccountsIdsWithActivePositionsLength) break;

            // get the `tradingAccountId` of the current active account
            uint128 tradingAccountId = activeAccountIds[i];

            // account can be liquidated if requiredMargin > marginBalance
            if (isLiquidatableAtIndex[i]) {
                liquidatableAccountsIds[i] = tradingAccountId; // @> VULN: absolute index `i`, should be `i - lowerBound`
                // FIX: liquidatableAccountsIds[i - lowerBound] = tradingAccountId;
            }
        }
    }
}

contract Exploit {
    LiquidationBranch public branch; // CREATE nonce 1

    constructor() {
        branch = new LiquidationBranch(); // nonce 1
    }

    /// @notice Mirrors the finding's own PoC scenario: 30 active accounts,
    ///         with indices 10..19 marked liquidatable (matching its
    ///         lowerBound=10 / upperBound=20 example). Shows the
    ///         lowerBound=0 segment works, then shows the lowerBound=10
    ///         segment reverts with an array out-of-bounds Panic.
    function run() external {
        for (uint256 i = 0; i < 30; i++) {
            bool liquidatable = (i >= 10 && i < 20);
            branch.addActiveAccount(uint128(100 + i), liquidatable);
        }

        // CONTROL: the first segment (lowerBound = 0) works fine — the
        // absolute index `i` and the relative offset coincide when
        // lowerBound is 0.
        uint128[] memory seg0 = branch.checkLiquidatableAccounts(0, 10);
        require(seg0.length == 10, "seg0: unexpected array length");

        // HARM: the second segment (lowerBound = 10, upperBound = 20)
        // contains liquidatable accounts (indices 10..19), but the array is
        // only 10 slots wide while `i` walks 10..19 — an immediate
        // out-of-bounds write the instant the first liquidatable account in
        // the segment is found.
        bytes memory callData = abi.encodeWithSignature("checkLiquidatableAccounts(uint256,uint256)", 10, 20);
        (bool ok, bytes memory ret) = address(branch).staticcall(callData);

        require(!ok, "expected checkLiquidatableAccounts(10,20) to revert (bug)");
        require(ret.length >= 36, "expected Panic(uint256) revert data"); // 4-byte selector + 32-byte code
        bytes4 selector = bytes4(ret);
        require(selector == 0x4e487b71, "expected Panic(uint256) selector"); // Panic(uint256)

        uint256 panicCode;
        assembly {
            panicCode := mload(add(ret, 0x24))
        }
        require(panicCode == 0x32, "expected array out-of-bounds panic code 0x32");
    }
}
