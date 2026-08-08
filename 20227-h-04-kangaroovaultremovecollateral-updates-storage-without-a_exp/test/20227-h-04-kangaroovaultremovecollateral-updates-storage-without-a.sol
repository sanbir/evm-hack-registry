// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Polynomial Protocol — [H-04] KangarooVault.removeCollateral updates storage
    without actually removing collateral, resulting in lost collateral
    (Code4rena 2023-03; finding #20227, reporter Bauer)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    KangarooVault.removeCollateral is inlined VERBATIM:

        require(positionData.totalCollateral >= minColl + collateralToRemove);
        usedFunds -= collateralToRemove;
        positionData.totalCollateral -= collateralToRemove;  // @> never calls
                                                             //    EXCHANGE.removeCollateral
        emit RemoveCollateral(positionData.positionId, collateralToRemove);

    Root cause: removeCollateral decrements the vault's collateral accounting
    (usedFunds, positionData.totalCollateral) but NEVER calls
    EXCHANGE.removeCollateral, so no collateral is actually pulled back from the
    Exchange. The "removed" collateral stays in the Exchange while the vault's
    books say it is gone. When the position is later closed, _closePosition
    caps the amount retrieved at the (already-decremented) totalCollateral, so
    the removed slice is never recovered — it is permanently stranded in the
    Exchange and lost to the vault's LPs.

    Harm class: loss of funds (collateral stranded / lost). No party profits, so
    this is surfaced as a zero-profit INVARIANT: run() ends with require()
    assertions that the vault recovered strictly less than it deposited and the
    missing slice sits unrecoverable in the Exchange.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal fixed-point helpers (solmate-compatible semantics).
library FixedPointMathLib {
    uint256 internal constant WAD = 1e18;

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }
}

/// @dev Minimal ERC20 (sUSD), the vault's collateral / LP capital.
contract MockERC20 {
    string public name = "Synthetic USD";
    string public symbol = "sUSD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal LiquidityPool — only getMarkPrice() is needed by removeCollateral.
contract LiquidityPool {
    uint256 public markPrice;

    constructor(uint256 _markPrice) {
        markPrice = _markPrice;
    }

    function getMarkPrice() external view returns (uint256, bool) {
        return (markPrice, false);
    }
}

/// @dev Minimal Exchange that actually custodies position collateral. The vault
///      MUST call EXCHANGE.removeCollateral to get collateral back — which is
///      exactly the call the vulnerable removeCollateral omits.
contract Exchange {
    MockERC20 public susd;
    mapping(uint256 => uint256) public collateralOf;

    constructor(MockERC20 _susd) {
        susd = _susd;
    }

    function addCollateral(uint256 positionId, uint256 amount) external {
        susd.transferFrom(msg.sender, address(this), amount);
        collateralOf[positionId] += amount;
    }

    /// @notice Pull collateral back to the caller. Never invoked by the buggy
    ///         KangarooVault.removeCollateral, so the collateral is stranded.
    function removeCollateral(uint256 positionId, uint256 amount) external {
        collateralOf[positionId] -= amount;
        susd.transfer(msg.sender, amount);
    }

    /// @notice Close the position: return `collateralAmount` collateral to the
    ///         caller. Faithful to _closeTrade -> sendCollateral, which returns
    ///         only the amount the vault passes (capped at its own accounting).
    function closeTrade(uint256 positionId, uint256 collateralAmount) external returns (uint256) {
        collateralOf[positionId] -= collateralAmount;
        susd.transfer(msg.sender, collateralAmount);
        return 0;
    }
}

/// @notice Reduced KangarooVault. Holds LP capital (sUSD), manages a single
///         short position's collateral through the Exchange. Contains the
///         verbatim vulnerable removeCollateral.
contract KangarooVault {
    using FixedPointMathLib for uint256;

    struct PositionData {
        uint256 positionId;
        uint256 shortAmount;
        uint256 totalCollateral;
        uint256 longPerp;
    }

    PositionData public positionData;
    MockERC20 public SUSD;
    Exchange public EXCHANGE;
    LiquidityPool public LIQUIDITY_POOL;

    uint256 public usedFunds;
    uint256 public collRatio;
    address public owner;

    event AddCollateral(uint256 positionId, uint256 amount);
    event RemoveCollateral(uint256 positionId, uint256 amount);

    modifier requiresAuth() {
        require(msg.sender == owner, "AUTH");
        _;
    }

    uint256 private _lock = 1;

    modifier nonReentrant() {
        require(_lock == 1, "REENTRANCY");
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(MockERC20 _susd, Exchange _exchange, LiquidityPool _pool, uint256 _collRatio) {
        owner = msg.sender;
        SUSD = _susd;
        EXCHANGE = _exchange;
        LIQUIDITY_POOL = _pool;
        collRatio = _collRatio;
    }

    /// @dev Test helper: register an open short position.
    function openPosition(uint256 positionId, uint256 shortAmount) external requiresAuth {
        positionData.positionId = positionId;
        positionData.shortAmount = shortAmount;
    }

    /// @notice Add collateral to the position (VERBATIM structure; transfers
    ///         collateral to the Exchange and updates accounting).
    function addCollateral(uint256 additionalCollateral) external requiresAuth nonReentrant {
        SUSD.approve(address(EXCHANGE), additionalCollateral);
        EXCHANGE.addCollateral(positionData.positionId, additionalCollateral);

        usedFunds += additionalCollateral;
        positionData.totalCollateral += additionalCollateral;

        emit AddCollateral(positionData.positionId, additionalCollateral);
    }

    /// @notice Remove collateral from the position. VERBATIM reduction of the
    ///         vulnerable Polynomial removeCollateral — it updates accounting
    ///         but never calls EXCHANGE.removeCollateral.
    function removeCollateral(uint256 collateralToRemove) external requiresAuth nonReentrant {
        (uint256 markPrice,) = LIQUIDITY_POOL.getMarkPrice();
        uint256 minColl = positionData.shortAmount.mulWadDown(markPrice);
        minColl = minColl.mulWadDown(collRatio);

        require(positionData.totalCollateral >= minColl + collateralToRemove);

        usedFunds -= collateralToRemove;
        positionData.totalCollateral -= collateralToRemove; // @> VULN: EXCHANGE.removeCollateral is never called, so no collateral is retrieved

        emit RemoveCollateral(positionData.positionId, collateralToRemove);
    }

    /// @notice Close the full position. Faithful reduction of _closePosition's
    ///         full-close branch: the amount retrieved is capped at
    ///         positionData.totalCollateral, which removeCollateral decremented.
    function closePosition() external requiresAuth nonReentrant {
        uint256 collateralAmount = positionData.totalCollateral; // capped by (decremented) totalCollateral
        EXCHANGE.closeTrade(positionData.positionId, collateralAmount);

        positionData.totalCollateral = 0;
        positionData.shortAmount = 0;
        usedFunds = 0;
    }
}

/// @dev Orchestrator: funds the vault with LP capital, adds collateral, calls
///      the buggy removeCollateral, closes the position, and asserts the
///      "removed" collateral was lost (stranded in the Exchange).
contract Exploit {
    uint256 public constant DEPOSIT = 3e18; // LP capital / collateral deposited
    uint256 public constant SHORT_AMOUNT = 1e18;
    uint256 public constant REMOVE = 1e18; // collateral "removed" (but never retrieved)
    uint256 public constant COLL_RATIO = 1.2e18; // 120%
    uint256 public constant MARK_PRICE = 1e18; // 1.0

    MockERC20 public susd;
    LiquidityPool public pool;
    Exchange public exchange;
    KangarooVault public vault;
    address public admin;

    constructor() {
        admin = msg.sender;
        susd = new MockERC20(); // CREATE nonce 1
        pool = new LiquidityPool(MARK_PRICE); // CREATE nonce 2
        exchange = new Exchange(susd); // CREATE nonce 3
        vault = new KangarooVault(susd, exchange, pool, COLL_RATIO); // CREATE nonce 4 (vulnerable)

        // Seed the vault with LP capital it will post as collateral.
        susd.mint(address(vault), DEPOSIT);
    }

    function run() external {
        // Open a short and post 3e18 collateral to the Exchange.
        vault.openPosition(1, SHORT_AMOUNT);
        vault.addCollateral(DEPOSIT);
        require(susd.balanceOf(address(vault)) == 0, "vault should have posted all collateral");
        require(susd.balanceOf(address(exchange)) == DEPOSIT, "exchange should custody collateral");

        // Remove 1e18 of collateral. Accounting is decremented but NO sUSD is
        // pulled back from the Exchange (the missing EXCHANGE.removeCollateral).
        vault.removeCollateral(REMOVE);
        (, , uint256 totalCollAfter,) = vault.positionData();
        require(totalCollAfter == DEPOSIT - REMOVE, "accounting not decremented");
        require(susd.balanceOf(address(vault)) == 0, "vault wrongly received removed collateral");
        require(susd.balanceOf(address(exchange)) == DEPOSIT, "collateral wrongly left the exchange");

        // Close the position: only the (decremented) totalCollateral is
        // retrieved. The removed slice stays stranded in the Exchange.
        vault.closePosition();

        // === HARM ===
        uint256 recovered = susd.balanceOf(address(vault));
        uint256 stranded = susd.balanceOf(address(exchange));

        // The vault recovered only DEPOSIT - REMOVE; the removed slice is lost.
        require(recovered == DEPOSIT - REMOVE, "vault recovered wrong amount");
        require(recovered < DEPOSIT, "no loss occurred");
        require(DEPOSIT - recovered == REMOVE, "loss != removed amount");

        // ...and the lost slice sits unrecoverable in the Exchange (position is
        // closed; there is no path left to pull it back to the vault).
        require(stranded == REMOVE, "stranded collateral != removed amount");
    }
}
