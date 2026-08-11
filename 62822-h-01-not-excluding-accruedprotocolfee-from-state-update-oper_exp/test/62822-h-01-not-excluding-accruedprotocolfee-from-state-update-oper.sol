// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Covenant finding 62822:
// "Not excluding accruedProtocolFee from state update operations causes several
//  issues" (Pashov Audit Group, H-01, Covenant 2025-08-18).
//
// When Covenant governance turns ON protocol fees, `_calculateMarketState`
// accrues a fee (fee = baseTokenSupply * rate) into `protocolFeeGrowth` but does
// NOT exclude that fee from the `baseTokenSupply` value used downstream. On a
// FULL/last redeem the code sets `amountOut = baseTokenSupply` (== the full
// baseSupply, because the fee was never excluded). The market-state update then
// computes `baseSupply - amountOut - protocolFees`, i.e.
// `baseSupply - baseSupply - protocolFees`, which UNDERFLOWS and reverts for ANY
// protocolFees > 0. The final redeemer can therefore never withdraw -> the whole
// base supply is permanently locked (redeem DoS).
//
// No public Covenant repo exists (Pashov private audit) => source is the
// embedded-solidity block from the finding, reproduced VERBATIM below on the two
// underflow-critical lines (the full-redeem branch and the state-update line).
// Pashov's report explicitly confirms the underflow.
//
// Only the full-redeem underflow DoS is reduced here (the reducible core). The
// parallel maxDebtValue / undercollateralization sub-issue depends on
// SqrtPriceMath / LatentMath / WadRayMath and is NOT modelled.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double, used only as the harm MARKER token (records the
///      locked base-supply magnitude at the DoS SINK). Not on the vulnerable path.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev The Covenant per-market accounting state (the fields the finding touches).
///      supplyAmounts[0] = zToken supply, supplyAmounts[1] = aToken supply.
struct MarketState {
    uint256 baseSupply; // storage-tracked total base supply
    uint256[2] supplyAmounts; // [0]=zToken supply, [1]=aToken supply
    uint256 baseTokenSupply; // supply value computed by _calculateMarketState
    uint256 protocolFeeGrowth; // accrued protocol fees
}

/// @dev Redeem parameters (the finding's state-update line reads `redeemParams.marketId`).
struct RedeemParams {
    uint256 marketId;
    uint256 aTokenAmountIn;
    uint256 zTokenAmountIn;
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. The two underflow-critical lines from the finding appear
// VERBATIM: the full-redeem branch (`amountOut = marketState.baseTokenSupply`)
// and the state-update line (`baseSupply - amountOut - protocolFees`).
// ─────────────────────────────────────────────────────────────────────────────
contract Covenant {
    uint256 internal constant FEE_DENOM = 10_000;

    mapping(uint256 => MarketState) internal marketState;
    uint256 public protocolFeeRate; // basis points; governance turns fees ON by setting > 0
    uint160 internal _targetSqrtPriceX96 = 79228162514264337593543950336; // 2**96 (unused placeholder)

    // Explicit getters (mapping is internal because the struct holds a fixed array).
    function baseSupplyOf(uint256 marketId) external view returns (uint256) {
        return marketState[marketId].baseSupply;
    }

    function baseTokenSupplyOf(uint256 marketId) external view returns (uint256) {
        return marketState[marketId].baseTokenSupply;
    }

    /// @notice Governance switches protocol fees on/off.
    function setProtocolFeeRate(uint256 rateBp) external {
        protocolFeeRate = rateBp;
    }

    /// @notice Seed a market's supply (a full redeem consumes exactly these amounts).
    function initMarket(uint256 marketId, uint256 baseSupply_, uint256 zSupply, uint256 aSupply) external {
        MarketState storage ms = marketState[marketId];
        ms.baseSupply = baseSupply_;
        ms.supplyAmounts[0] = zSupply;
        ms.supplyAmounts[1] = aSupply;
        ms.baseTokenSupply = baseSupply_;
    }

    /// @dev Minimal faithful reconstruction of the fee accrual in _calculateMarketState.
    ///      Fee is added to protocolFeeGrowth but is NOT excluded from the
    ///      baseTokenSupply value used by downstream operations (the root cause).
    function _calculateMarketState(uint256 marketId)
        internal
        view
        returns (MarketState memory marketStateMem, uint256 protocolFees)
    {
        marketStateMem = marketState[marketId];
        // Accrue fee based on baseTokenSupply.
        protocolFees = (marketStateMem.baseTokenSupply * protocolFeeRate) / FEE_DENOM;
        marketStateMem.protocolFeeGrowth += protocolFees;
        // ROOT CAUSE: accrued protocolFees is NOT excluded from baseTokenSupply here,
        //    so downstream operations use the fee-inclusive (full) baseTokenSupply.
    }

    /// @dev Faithful reconstruction of the redeem amount-out helper. `marketState`
    ///      here is the MEMORY market-state (shadowing the storage mapping, exactly
    ///      as in the audited source where the helper takes a MarketState memory arg).
    function _computeAmountOut(MarketState memory marketState, uint256 aTokenAmountIn, uint256 zTokenAmountIn)
        internal
        view
        returns (uint256 amountOut, uint160 nextSqrtPriceX96)
    {
        // VERBATIM full-redeem branch from the finding:
        if (aTokenAmountIn == marketState.supplyAmounts[1] && zTokenAmountIn == marketState.supplyAmounts[0]) {
            amountOut = marketState.baseTokenSupply;
            nextSqrtPriceX96 = _targetSqrtPriceX96;
        }
    }

    /// @notice Redeem. On a full redeem with fees on, the state update underflows.
    function redeem(RedeemParams memory redeemParams) external returns (uint256 amountOut) {
        uint256 baseSupply = marketState[redeemParams.marketId].baseSupply;
        (MarketState memory calculatedState, uint256 protocolFees) = _calculateMarketState(redeemParams.marketId);

        (amountOut,) = _computeAmountOut(calculatedState, redeemParams.aTokenAmountIn, redeemParams.zTokenAmountIn);

        // Update market state (storage). VERBATIM state-update line from the finding:
        marketState[redeemParams.marketId].baseSupply = baseSupply - amountOut - protocolFees; // @> full redeem sets amountOut=baseTokenSupply(==baseSupply, fee never excluded); subtracting protocolFees>0 underflows -> full/last redeem reverts, base supply locked
        if (protocolFees > 0) marketState[redeemParams.marketId].protocolFeeGrowth += protocolFees;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (the recommended fix): exclude the accrued fee from
// baseTokenSupply BEFORE it is used downstream. Full redeem then succeeds and the
// base supply goes to 0 as intended.
// ─────────────────────────────────────────────────────────────────────────────
contract CovenantFixed {
    uint256 internal constant FEE_DENOM = 10_000;

    mapping(uint256 => MarketState) internal marketState;
    uint256 public protocolFeeRate;
    uint160 internal _targetSqrtPriceX96 = 79228162514264337593543950336;

    function baseSupplyOf(uint256 marketId) external view returns (uint256) {
        return marketState[marketId].baseSupply;
    }

    function setProtocolFeeRate(uint256 rateBp) external {
        protocolFeeRate = rateBp;
    }

    function initMarket(uint256 marketId, uint256 baseSupply_, uint256 zSupply, uint256 aSupply) external {
        MarketState storage ms = marketState[marketId];
        ms.baseSupply = baseSupply_;
        ms.supplyAmounts[0] = zSupply;
        ms.supplyAmounts[1] = aSupply;
        ms.baseTokenSupply = baseSupply_;
    }

    function _calculateMarketState(uint256 marketId)
        internal
        view
        returns (MarketState memory marketStateMem, uint256 protocolFees)
    {
        marketStateMem = marketState[marketId];
        protocolFees = (marketStateMem.baseTokenSupply * protocolFeeRate) / FEE_DENOM;
        marketStateMem.protocolFeeGrowth += protocolFees;
        // FIX: exclude the accrued fee from baseTokenSupply before downstream use.
        marketStateMem.baseTokenSupply = marketStateMem.baseTokenSupply - protocolFees;
    }

    function _computeAmountOut(MarketState memory marketState, uint256 aTokenAmountIn, uint256 zTokenAmountIn)
        internal
        view
        returns (uint256 amountOut, uint160 nextSqrtPriceX96)
    {
        if (aTokenAmountIn == marketState.supplyAmounts[1] && zTokenAmountIn == marketState.supplyAmounts[0]) {
            amountOut = marketState.baseTokenSupply;
            nextSqrtPriceX96 = _targetSqrtPriceX96;
        }
    }

    function redeem(RedeemParams memory redeemParams) external returns (uint256 amountOut) {
        uint256 baseSupply = marketState[redeemParams.marketId].baseSupply;
        (MarketState memory calculatedState, uint256 protocolFees) = _calculateMarketState(redeemParams.marketId);

        (amountOut,) = _computeAmountOut(calculatedState, redeemParams.aTokenAmountIn, redeemParams.zTokenAmountIn);

        // With the fix, amountOut = baseSupply - fee, so this equals fee - fee = 0 (no underflow).
        marketState[redeemParams.marketId].baseSupply = baseSupply - amountOut - protocolFees;
        if (protocolFees > 0) marketState[redeemParams.marketId].protocolFeeGrowth += protocolFees;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: governance turns fees on, a full/last redeem is attempted, and
// it reverts by underflow. The harm (the redeemer's entire base supply is locked)
// is recorded on the MARKER token minted to the DoS SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    Covenant public covenant;
    CovenantFixed public covenantFixed;
    MiniToken public marker;

    uint256 public constant MARKET_ID = 1;
    uint256 public constant BASE_SUPPLY = 1_000_000 ether;
    uint256 public constant Z_SUPPLY = 400_000 ether;
    uint256 public constant A_SUPPLY = 600_000 ether;
    uint256 public constant FEE_RATE_BP = 100; // 1% -> any non-zero rate triggers the bug

    // Exposed results.
    bool public fullRedeemReverted;
    uint256 public lockedBaseSupply;
    uint256 public sinkMarkerBalance;
    uint256 public expectedProtocolFee;
    address public covenantAddr;
    address public covenantFixedAddr;
    address public markerAddr;

    constructor() {
        covenant = new Covenant(); // deploy index 0
        covenantFixed = new CovenantFixed(); // deploy index 1
        marker = new MiniToken("Locked Base Supply", "LOCKED-BASE"); // deploy index 2 (LAST)
        covenantAddr = address(covenant);
        covenantFixedAddr = address(covenantFixed);
        markerAddr = address(marker);
    }

    function run() external payable {
        // --- governance turns protocol fees ON, then a market is seeded ---
        covenant.setProtocolFeeRate(FEE_RATE_BP);
        covenant.initMarket(MARKET_ID, BASE_SUPPLY, Z_SUPPLY, A_SUPPLY);
        expectedProtocolFee = (BASE_SUPPLY * FEE_RATE_BP) / 10_000; // 10_000 ether

        // --- the final redeemer attempts to withdraw the ENTIRE market (full redeem) ---
        RedeemParams memory rp =
            RedeemParams({marketId: MARKET_ID, aTokenAmountIn: A_SUPPLY, zTokenAmountIn: Z_SUPPLY});

        // The state update underflows (baseSupply - baseSupply - protocolFees), reverting.
        try covenant.redeem(rp) returns (uint256) {
            fullRedeemReverted = false;
        } catch {
            fullRedeemReverted = true;
        }
        require(fullRedeemReverted, "full redeem must underflow-revert when fees are on");

        // --- HARM: the base supply can never be redeemed; it is permanently locked ---
        lockedBaseSupply = covenant.baseSupplyOf(MARKET_ID); // still the full BASE_SUPPLY
        require(lockedBaseSupply == BASE_SUPPLY, "entire base supply remains locked");

        // Record the locked magnitude on the marker at the SINK (DoS harm marker).
        marker.mint(SINK, lockedBaseSupply);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
