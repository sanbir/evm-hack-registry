// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Myriad (Polkamarkets CLOB) finding
// 65418: "Oracle void outcome leaves PredictionMarketV3ManagerCLOB.voidedPayouts
// unset, locking collateral".
//
// PredictionMarketV3ManagerCLOB.resolveMarket accepts an oracle outcome of -1
// (reality.eth encodes invalid/unanswered questions as 0xff..ff, which cast to
// int256 is exactly -1 == Outcomes.VOIDED). It marks the market resolved with
// resolvedOutcome = -1 but NEVER populates voidedPayouts[marketId], which stays
// at its default [0, 0].
//
// When a position holder later calls ConditionalTokens.redeemVoided, that
// function reads getVoidedPayouts (which returns (0, 0) for the market) and
// asserts the two payouts sum to 1e18. 0 + 0 != 1e18, so the redemption ALWAYS
// reverts. All collateral backing the outcome tokens is frozen inside
// ConditionalTokens with no immediate recovery path (the manager is UUPS
// upgradeable, so unlocking requires a full patch/audit/deploy cycle).
//
// Verbatim vulnerable source (imports/pragma stripped; pre-fix commit 9169487~1
// of Polkamarkets/polkamarkets-js) is inlined below with `// @>` on the
// defective line. Only the opaque oracle FEED is doubled (MockMarketOracle);
// the vulnerable manager + ConditionalTokens are the real logic.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Verbatim outcome constants (contracts/Outcomes.sol).
library Outcomes {
    uint256 internal constant YES = 0;
    uint256 internal constant NO = 1;
    int256 internal constant VOIDED = -1;
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal ERC20 double. Used as the market collateral (held by
///      ConditionalTokens) and, separately, as the LOCKED-collateral marker.
contract MiniToken is IERC20Like {
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Oracle FEED double (opaque external boundary — the only mocked component).
// reality.eth returns 0xff..ff for invalid/unanswered questions; cast to int256
// this is -1. We reproduce exactly that: getResult -> (-1, true).
// ─────────────────────────────────────────────────────────────────────────────
interface IMarketOracle {
    function getResult(uint256 marketId) external view returns (int256 outcome, bool resolved);
}

contract MockMarketOracle is IMarketOracle {
    int256 public outcome;
    bool public resolved;

    function setResult(int256 _outcome, bool _resolved) external {
        outcome = _outcome;
        resolved = _resolved;
    }

    function getResult(uint256) external view returns (int256, bool) {
        return (outcome, resolved);
    }
}

interface IPMManager {
    function getVoidedPayouts(uint256 marketId) external view returns (uint256, uint256);
    function getMarketResolvedOutcome(uint256 marketId) external view returns (int256);
    function getMarketCollateral(uint256 marketId) external view returns (IERC20Like);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE manager. resolveMarket verbatim (pre-fix): accepts outcome -1 and
// resolves the market WITHOUT populating voidedPayouts, leaving it [0, 0].
// ─────────────────────────────────────────────────────────────────────────────
contract PredictionMarketV3ManagerCLOB is IPMManager {
    uint256 internal constant ONE = 1e18;

    enum MarketState {
        open,
        closed,
        resolved
    }

    struct Market {
        address oracle;
        MarketState state;
        int256 resolvedOutcome;
        IERC20Like collateral;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 marketId => uint256[2] payouts) internal voidedPayouts; // [outcome0Payout, outcome1Payout] in 1e18
    uint256 public marketCount;

    function createMarket(address oracle, IERC20Like collateral) external returns (uint256 marketId) {
        marketId = marketCount++;
        Market storage market = markets[marketId];
        market.oracle = oracle;
        market.state = MarketState.closed; // closed and awaiting resolution
        market.resolvedOutcome = -3; // "unresolved" sentinel (verbatim protocol value)
        market.collateral = collateral;
    }

    function resolveMarket(uint256 marketId) external returns (int256 outcomeId) {
        Market storage market = markets[marketId];
        require(market.oracle != address(0), "no oracle");
        require(market.state != MarketState.resolved, "resolved");

        (int256 outcome, bool resolved) = IMarketOracle(market.oracle).getResult(marketId);
        require(resolved, "oracle: not resolved");
        require(outcome == 0 || outcome == 1 || outcome == -1, "invalid outcome"); // @> accepts -1 (VOIDED) but never sets voidedPayouts[marketId], leaving it [0,0]

        market.resolvedOutcome = outcome; // can be -1
        market.state = MarketState.resolved;
        // voidedPayouts[marketId] is never set - defaults to [0, 0]
        return outcome;
    }

    /// @notice Correct void path: sets payout ratios that sum to 1e18.
    function adminVoidMarket(uint256 marketId, uint256 outcome0Payout, uint256 outcome1Payout)
        external
        returns (int256)
    {
        require(outcome0Payout + outcome1Payout == ONE, "payouts must sum to 1e18");
        Market storage market = markets[marketId];
        require(market.state != MarketState.resolved, "resolved");

        market.resolvedOutcome = Outcomes.VOIDED;
        market.state = MarketState.resolved;
        voidedPayouts[marketId] = [outcome0Payout, outcome1Payout];
        return -1;
    }

    function getVoidedPayouts(uint256 marketId) external view returns (uint256 outcome0Payout, uint256 outcome1Payout) {
        Market storage market = markets[marketId];
        require(market.resolvedOutcome == Outcomes.VOIDED, "not voided");
        outcome0Payout = voidedPayouts[marketId][0];
        outcome1Payout = voidedPayouts[marketId][1];
    }

    function getMarketResolvedOutcome(uint256 marketId) external view returns (int256) {
        return markets[marketId].resolvedOutcome;
    }

    function getMarketCollateral(uint256 marketId) external view returns (IERC20Like) {
        return markets[marketId].collateral;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED manager (recommended mitigation): resolveMarket rejects outcome == -1,
// forcing all voids through adminVoidMarket. Used as a negative control.
// ─────────────────────────────────────────────────────────────────────────────
contract PredictionMarketV3ManagerCLOBFixed is IPMManager {
    uint256 internal constant ONE = 1e18;

    enum MarketState {
        open,
        closed,
        resolved
    }

    struct Market {
        address oracle;
        MarketState state;
        int256 resolvedOutcome;
        IERC20Like collateral;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 marketId => uint256[2] payouts) internal voidedPayouts;
    uint256 public marketCount;

    function createMarket(address oracle, IERC20Like collateral) external returns (uint256 marketId) {
        marketId = marketCount++;
        Market storage market = markets[marketId];
        market.oracle = oracle;
        market.state = MarketState.closed;
        market.resolvedOutcome = -3;
        market.collateral = collateral;
    }

    function resolveMarket(uint256 marketId) external returns (int256 outcomeId) {
        Market storage market = markets[marketId];
        require(market.oracle != address(0), "no oracle");
        require(market.state != MarketState.resolved, "resolved");

        (int256 outcome, bool resolved) = IMarketOracle(market.oracle).getResult(marketId);
        require(resolved, "oracle: not resolved");
        require(outcome == 0 || outcome == 1, "oracle: invalid outcome"); // FIX: -1 rejected -> forced through adminVoidMarket

        market.resolvedOutcome = outcome;
        market.state = MarketState.resolved;
        return outcome;
    }

    function adminVoidMarket(uint256 marketId, uint256 outcome0Payout, uint256 outcome1Payout)
        external
        returns (int256)
    {
        require(outcome0Payout + outcome1Payout == ONE, "payouts must sum to 1e18");
        Market storage market = markets[marketId];
        require(market.state != MarketState.resolved, "resolved");
        market.resolvedOutcome = Outcomes.VOIDED;
        market.state = MarketState.resolved;
        voidedPayouts[marketId] = [outcome0Payout, outcome1Payout];
        return -1;
    }

    function getVoidedPayouts(uint256 marketId) external view returns (uint256, uint256) {
        Market storage market = markets[marketId];
        require(market.resolvedOutcome == Outcomes.VOIDED, "not voided");
        return (voidedPayouts[marketId][0], voidedPayouts[marketId][1]);
    }

    function getMarketResolvedOutcome(uint256 marketId) external view returns (int256) {
        return markets[marketId].resolvedOutcome;
    }

    function getMarketCollateral(uint256 marketId) external view returns (IERC20Like) {
        return markets[marketId].collateral;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE ConditionalTokens. redeemVoided verbatim: reads getVoidedPayouts and
// requires the two payouts sum to 1e18 before returning any collateral. For an
// oracle-voided market voidedPayouts is [0,0] -> 0 + 0 != 1e18 -> always reverts.
// ERC1155-style outcome-token balances modelled with a single balance mapping.
// ─────────────────────────────────────────────────────────────────────────────
contract ConditionalTokens {
    IPMManager public manager;

    // tokenId => account => balance (outcome tokens)
    mapping(uint256 => mapping(address => uint256)) public balances;

    constructor(address _manager) {
        manager = IPMManager(_manager);
    }

    function getTokenId(uint256 marketId, uint256 outcome) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(marketId, outcome)));
    }

    function balanceOf(address account, uint256 tokenId) public view returns (uint256) {
        return balances[tokenId][account];
    }

    /// @notice Deposit `amount` collateral, receive `amount` of each outcome token.
    ///         The deposited collateral now sits inside this contract.
    function splitPosition(uint256 marketId, uint256 amount) external {
        IERC20Like collateral = manager.getMarketCollateral(marketId);
        collateral.transferFrom(msg.sender, address(this), amount);
        balances[getTokenId(marketId, Outcomes.YES)][msg.sender] += amount;
        balances[getTokenId(marketId, Outcomes.NO)][msg.sender] += amount;
    }

    function redeemVoided(uint256 marketId) external {
        int256 outcome = manager.getMarketResolvedOutcome(marketId);
        require(outcome == Outcomes.VOIDED, "not voided");

        (uint256 outcome0Payout, uint256 outcome1Payout) = manager.getVoidedPayouts(marketId);
        require(outcome0Payout + outcome1Payout == 1e18, "invalid payout ratios"); // @> voided market: voidedPayouts=[0,0] -> 0+0 != 1e18 -> reverts, collateral frozen

        IERC20Like collateral = manager.getMarketCollateral(marketId);
        uint256 outcome0Id = getTokenId(marketId, Outcomes.YES);
        uint256 outcome1Id = getTokenId(marketId, Outcomes.NO);
        uint256 outcome0Balance = balances[outcome0Id][msg.sender];
        uint256 outcome1Balance = balances[outcome1Id][msg.sender];
        require(outcome0Balance > 0 || outcome1Balance > 0, "no balance");

        uint256 totalPayout;
        if (outcome0Balance > 0) {
            balances[outcome0Id][msg.sender] = 0;
            totalPayout += (outcome0Balance * outcome0Payout) / 1e18;
        }
        if (outcome1Balance > 0) {
            balances[outcome1Id][msg.sender] = 0;
            totalPayout += (outcome1Balance * outcome1Payout) / 1e18;
        }
        require(totalPayout > 0, "zero payout");
        collateral.transfer(msg.sender, totalPayout);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a holder deposits collateral into ConditionalTokens, the market
// is resolved via the oracle's void (-1) outcome, and the holder can never
// redeem — collateral stays frozen in ConditionalTokens. The frozen magnitude is
// recorded on a LOCKED-collateral marker token minted to the SINK (lock/DoS).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant DEPOSIT = 1e18;

    // deployed components
    MiniToken public collateral;
    PredictionMarketV3ManagerCLOB public manager;
    MockMarketOracle public oracle;
    ConditionalTokens public conditionalTokens;
    MiniToken public marker;

    // exposed results / addresses for the driver
    uint256 public marketId;
    bool public redeemReverted;
    uint256 public lockedCollateral;
    uint256 public sinkMarkerBalance;
    address public managerAddr;
    address public conditionalTokensAddr;
    address public collateralAddr;
    address public markerAddr;

    constructor() {
        collateral = new MiniToken("Collateral", "COLL"); // deploy 0
        manager = new PredictionMarketV3ManagerCLOB(); // deploy 1
        oracle = new MockMarketOracle(); // deploy 2
        conditionalTokens = new ConditionalTokens(address(manager)); // deploy 3
        marker = new MiniToken("Locked Collateral", "LOCKED-COLL"); // deploy 4 (LAST)

        managerAddr = address(manager);
        conditionalTokensAddr = address(conditionalTokens);
        collateralAddr = address(collateral);
        markerAddr = address(marker);
    }

    function run() external payable {
        // reality.eth returns 0xff..ff (== -1) for an invalid/timed-out question
        oracle.setResult(-1, true);

        // create the market wired to the void oracle + collateral token
        marketId = manager.createMarket(address(oracle), collateral);

        // holder acquires a position: deposit collateral, receive outcome tokens.
        // The collateral now sits inside ConditionalTokens, backing the position.
        collateral.mint(address(this), DEPOSIT);
        collateral.approve(address(conditionalTokens), DEPOSIT);
        conditionalTokens.splitPosition(marketId, DEPOSIT);

        // resolveMarket accepts the oracle's -1 and marks the market resolved,
        // but leaves voidedPayouts[marketId] at its default [0, 0].
        manager.resolveMarket(marketId);

        // holder tries to redeem the voided market -> reverts (0 + 0 != 1e18).
        try conditionalTokens.redeemVoided(marketId) {
            redeemReverted = false;
        } catch {
            redeemReverted = true;
        }
        require(redeemReverted, "redeemVoided unexpectedly succeeded");

        // HARM: the full deposit is frozen inside ConditionalTokens, unredeemable.
        lockedCollateral = collateral.balanceOf(address(conditionalTokens));
        require(lockedCollateral == DEPOSIT, "collateral not fully locked");

        // record the frozen magnitude on the marker to the SINK (lock/DoS marker).
        marker.mint(SINK, lockedCollateral);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
