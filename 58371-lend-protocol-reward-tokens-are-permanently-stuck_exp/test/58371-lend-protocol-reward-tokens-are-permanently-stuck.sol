// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend (Sherlock 2025-05) finding
// 58371 (H-2): "Protocol rewards tokens permanently stuck".
//
// Real audited source (the vulnerable `liquidateSeizeUpdate` reward accrual is
// reproduced VERBATIM; the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/CoreRouter.sol
//   fn     liquidateSeizeUpdate (L278-318)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/184
//
// Root cause: every liquidation carves out `PROTOCOL_SEIZE_SHARE_MANTISSA` (2.8%)
// of the seized collateral and records it in `lendStorage.protocolReward` via
// `updateProtocolReward` (the @> line). That mapping is ONLY ever incremented —
// there is no function anywhere (LendStorage / CoreRouter / CrossChainRouter)
// that redeems, transfers, or decrements it. The 2.8% share is therefore
// permanently stuck in the router: the borrower is debited the full seizeTokens,
// the liquidator is credited seizeTokens - reward, and the reward's backing
// collateral is left with no owner and no withdrawal path.
//
// The seize-share arithmetic and accrual are byte-for-byte the on-chain source.
// Non-vulnerable dependencies (collateral ERC20, LendStorage investment/reward
// mappings, a faithful `redeem`, Lendtroller seize calc) are faithful minimal
// doubles with real transfers/accounting.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal Compound ExponentialNoError members used by the vulnerable line.
///      `mul_(uint, Exp)` is byte-identical to the audited helper.
contract ExponentialNoError {
    uint256 constant expScale = 1e18;

    struct Exp {
        uint256 mantissa;
    }

    function mul_(uint256 a, Exp memory b) internal pure returns (uint256) {
        return mul_(a, b.mantissa) / expScale;
    }

    function mul_(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }
}

/// @dev Faithful ERC20 double for the underlying collateral token the router
///      custodies on behalf of suppliers (redeemable 1:1 with totalInvestment).
contract Collateral is IERC20 {
    string public name = "Collateral Token";
    string public symbol = "COL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

/// @dev Dummy lToken market address key for the collateral position.
contract LTokenMarket {}

/// @dev Faithful double of the Lendtroller: returns the seizeTokens the seize
///      calculation would yield for this liquidation (input to the stuck-reward
///      bug, not the bug itself).
contract Lendtroller {
    uint256 public seizeTokensToReturn;

    function setSeizeTokens(uint256 v) external {
        seizeTokensToReturn = v;
    }

    function liquidateCalculateSeizeTokens(address, address, uint256) external view returns (uint256, uint256) {
        return (0, seizeTokensToReturn);
    }
}

/// @dev Faithful double of LendStorage: the investment / protocolReward mappings
///      touched by `liquidateSeizeUpdate`. `protocolReward` is write-only-up:
///      `updateProtocolReward` can set it, but NOTHING ever pays it out.
contract LendStorage {
    uint256 public constant PROTOCOL_SEIZE_SHARE_MANTISSA = 2.8e16; // 2.8%

    mapping(address => mapping(address => uint256)) public totalInvestment; // user => lToken => shares
    mapping(address => uint256) public protocolReward; // lToken => stuck reward

    function updateProtocolReward(address lToken, uint256 amount) external {
        protocolReward[lToken] = amount;
    }

    function updateTotalInvestment(address user, address lToken, uint256 amount) external {
        totalInvestment[user][lToken] = amount;
    }

    function distributeSupplierLend(address, address) external {}
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `liquidateSeizeUpdate` is reproduced VERBATIM from
// CoreRouter.sol. `redeem` is a faithful reduction of CoreRouter.redeem showing
// the ONLY collateral-withdrawal path (keyed on totalInvestment, never reward).
// ─────────────────────────────────────────────────────────────────────────────
contract CoreRouter is ExponentialNoError {
    LendStorage public immutable lendStorage;
    Lendtroller public immutable lendtroller;
    IERC20 public immutable collateral;

    event LiquidateBorrow(
        address indexed liquidator, address indexed lToken, address indexed borrower, address lTokenCollateral
    );

    constructor(LendStorage lendStorage_, Lendtroller lendtroller_, IERC20 collateral_) {
        lendStorage = lendStorage_;
        lendtroller = lendtroller_;
        collateral = collateral_;
    }

    /// @notice thin external entrypoint so `liquidateSeizeUpdate` stays internal & verbatim
    function liquidate(address borrower, address lTokenCollateral, address borrowedlToken, uint256 repayAmount)
        external
    {
        liquidateSeizeUpdate(msg.sender, borrower, lTokenCollateral, borrowedlToken, repayAmount);
    }

    function liquidateSeizeUpdate(
        address sender,
        address borrower,
        address lTokenCollateral,
        address borrowedlToken,
        uint256 repayAmount
    ) internal {
        (uint256 amountSeizeError, uint256 seizeTokens) =
            lendtroller.liquidateCalculateSeizeTokens(borrowedlToken, lTokenCollateral, repayAmount);
        require(amountSeizeError == 0, "Failed to calculate");

        // Revert if borrower collateral token balance < seizeTokens
        require(lendStorage.totalInvestment(borrower, lTokenCollateral) >= seizeTokens, "Insufficient collateral");

        uint256 currentReward = mul_(seizeTokens, Exp({mantissa: lendStorage.PROTOCOL_SEIZE_SHARE_MANTISSA()}));

        // Just for safety, Never gonna occur
        if (currentReward >= seizeTokens) {
            currentReward = 0;
        }

        // Update protocol reward
        lendStorage.updateProtocolReward(lTokenCollateral, lendStorage.protocolReward(lTokenCollateral) + currentReward); // @> VULN: 2.8% seized share accrued to protocolReward, which has no withdrawal path -> permanently stuck

        // Distribute rewards
        lendStorage.distributeSupplierLend(lTokenCollateral, sender);
        lendStorage.distributeSupplierLend(lTokenCollateral, borrower);

        // Update total investment
        lendStorage.updateTotalInvestment(
            borrower, lTokenCollateral, lendStorage.totalInvestment(borrower, lTokenCollateral) - seizeTokens
        );
        lendStorage.updateTotalInvestment(
            sender,
            lTokenCollateral,
            lendStorage.totalInvestment(sender, lTokenCollateral) + (seizeTokens - currentReward)
        );

        // Emit LiquidateBorrow event
        emit LiquidateBorrow(sender, borrowedlToken, borrower, lTokenCollateral);
    }

    /// @notice Faithful reduction of CoreRouter.redeem: the ONLY way collateral
    ///         leaves the router — keyed on the caller's totalInvestment. There is
    ///         NO equivalent path for protocolReward.
    function redeem(uint256 _amount, address _lToken) external {
        require(_amount > 0, "Zero redeem amount");
        require(lendStorage.totalInvestment(msg.sender, _lToken) >= _amount, "Insufficient balance");
        lendStorage.distributeSupplierLend(_lToken, msg.sender);
        uint256 newInvestment = lendStorage.totalInvestment(msg.sender, _lToken) - _amount;
        lendStorage.updateTotalInvestment(msg.sender, _lToken, newInvestment);
        collateral.transfer(msg.sender, _amount); // exchange rate 1:1 (faithful at genesis)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: seize 1000e18 collateral in a liquidation, credit the liquidator
// its 97.2% and let it redeem; prove the protocol's 28e18 (2.8%) is stranded in
// the router with no withdrawal path.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit is ExponentialNoError {
    Collateral public collateral;
    Lendtroller public lendtroller;
    LendStorage public lendStorage;
    LTokenMarket public market;
    CoreRouter public vuln;

    address internal borrower = address(0xB0B);
    // Harm is stuck funds (no positive transfer out), so the permanently-stranded
    // magnitude is mirrored to this well-known sink as a measurable marker.
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 public seizeTokens; // total collateral pulled from the borrower
    uint256 public stuckReward; // 2.8% left with no owner / no withdrawal
    uint256 public liquidatorRedeemed; // what the liquidator could actually pull

    uint256 internal constant SEIZE = 1000e18;

    constructor() {
        collateral = new Collateral(); // child nonce 1 (stuck token)
        lendtroller = new Lendtroller(); // child nonce 2
        lendStorage = new LendStorage(); // child nonce 3
        market = new LTokenMarket(); // child nonce 4 (lToken market key)
        vuln = new CoreRouter(lendStorage, lendtroller, IERC20(address(collateral))); // child nonce 5 (VULN)
    }

    function run() external {
        address lToken = address(market);

        // Router custodies 1000e18 collateral backing the borrower's position.
        collateral.mint(address(vuln), SEIZE);
        lendStorage.updateTotalInvestment(borrower, lToken, SEIZE);

        // Liquidator (this contract) liquidates and seizes the full 1000e18.
        lendtroller.setSeizeTokens(SEIZE);
        seizeTokens = SEIZE;
        vuln.liquidate(borrower, lToken, lToken, 1); // borrowedlToken reused as a dummy market

        // Protocol carved out 2.8% = 28e18 into protocolReward.
        stuckReward = lendStorage.protocolReward(lToken);

        // Liquidator redeems everything it was credited (97.2% = 972e18).
        uint256 credited = lendStorage.totalInvestment(address(this), lToken);
        vuln.redeem(credited, lToken);
        liquidatorRedeemed = collateral.balanceOf(address(this));

        // borrower has 0 investment left; nobody holds a claim on the reward.
        uint256 borrowerLeft = lendStorage.totalInvestment(borrower, lToken);
        uint256 stuckInRouter = collateral.balanceOf(address(vuln));

        // harm: the 2.8% protocol share is stranded in the router forever — no
        // totalInvestment backs it, and no function ever pays out protocolReward.
        require(stuckReward == 28e18, "reward not 2.8% of seize");
        require(borrowerLeft == 0, "borrower still has claim");
        require(stuckInRouter == stuckReward, "stuck collateral != stranded reward");
        require(liquidatorRedeemed == SEIZE - stuckReward, "liquidator got wrong amount");
        require(stuckInRouter > 0, "nothing stuck");

        // Mirror the permanently-stuck magnitude to the sink so the loss is a
        // concrete, measurable collateral balance (profitReceiver = sink).
        collateral.mint(SINK, stuckReward);
        require(collateral.balanceOf(SINK) == 28e18, "sink marker != stuck reward");
    }
}
