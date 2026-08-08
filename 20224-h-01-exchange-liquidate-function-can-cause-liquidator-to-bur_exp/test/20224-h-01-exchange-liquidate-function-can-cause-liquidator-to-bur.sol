// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Polynomial Protocol — Exchange._liquidate burns too much powerPerp
    (Code4rena 2023-03-polynomial, finding #20224, H-01, reporter rbserver)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    When ShortCollateral.liquidate caps totalCollateralReturned to the
    position's remaining collateral (underwater after a collateral price crash),
    Exchange._liquidate still burns the FULL debtRepaying of powerPerp from the
    liquidator. The liquidator pays more powerPerp than the collateral they
    receive is worth — net loss of the excess powerPerp.

    Harm: liquidator burns 1000 powerPerp but only receives collateral worth
    ~500 powerPerp (measured as collateral transferred << expected claim).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "ALLOW");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
    }
}

contract ShortToken {
    struct ShortPosition {
        address collateral;
        uint256 shortAmount;
        uint256 collateralAmount;
        uint256 positionId;
    }

    mapping(uint256 => address) internal _ownerOf;
    mapping(uint256 => ShortPosition) public shortPositions;
    address public exchange;

    function setExchange(address e) external {
        require(exchange == address(0), "SET");
        exchange = e;
    }

    modifier onlyExchange() {
        require(msg.sender == exchange, "ONLY_EXCHANGE");
        _;
    }

    function ownerOf(uint256 id) public view returns (address o) {
        require((o = _ownerOf[id]) != address(0), "NOT_MINTED");
    }

    function mintPosition(address trader, address collateral, uint256 shortAmt, uint256 collAmt)
        external
        onlyExchange
        returns (uint256 id)
    {
        id = 1;
        _ownerOf[id] = trader;
        shortPositions[id] =
            ShortPosition({collateral: collateral, shortAmount: shortAmt, collateralAmount: collAmt, positionId: id});
    }

    function adjustPosition(
        uint256 positionId,
        address trader,
        address collateral,
        uint256 shortAmount,
        uint256 collateralAmount
    ) external onlyExchange {
        require(trader == ownerOf(positionId));
        ShortPosition storage p = shortPositions[positionId];
        p.collateral = collateral;
        p.shortAmount = shortAmount;
        p.collateralAmount = collateralAmount;
        if (shortAmount == 0) {
            delete _ownerOf[positionId];
        }
    }

    function getPosition(uint256 id) external view returns (ShortPosition memory) {
        return shortPositions[id];
    }
}

/// @notice Reduced ShortCollateral.liquidate with the underwater cap.
contract ShortCollateral {
    struct UserCollateral {
        address collateral;
        uint256 amount;
    }

    mapping(uint256 => UserCollateral) public userCollaterals;
    ShortToken public immutable shortToken;
    address public exchange;
    // Prices in 1e18; markPrice / collateralPrice drive the claim size.
    uint256 public markPrice = 1e18;
    uint256 public collateralPrice = 1e18;
    uint256 public constant LIQ_BONUS_WAD = 0.1e18; // 10%

    constructor(ShortToken st) {
        shortToken = st;
    }

    function setExchange(address e) external {
        require(exchange == address(0), "SET");
        exchange = e;
    }

    function setPrices(uint256 mark, uint256 coll) external {
        markPrice = mark;
        collateralPrice = coll;
    }

    function collectCollateral(uint256 positionId, address collateral, uint256 amount) external {
        require(msg.sender == exchange, "ONLY_EXCHANGE");
        UserCollateral storage uc = userCollaterals[positionId];
        uc.collateral = collateral;
        uc.amount += amount;
    }

    function maxLiquidatableDebt(uint256 /*positionId*/ ) external pure returns (uint256) {
        return type(uint256).max; // allow full requested debtRepaying for the PoC
    }

    /// @dev Faithful reduction of ShortCollateral.liquidate.
    function liquidate(uint256 positionId, uint256 debt, address user)
        external
        returns (uint256 totalCollateralReturned)
    {
        require(msg.sender == exchange, "ONLY_EXCHANGE");
        UserCollateral storage userCollateral = userCollaterals[positionId];

        uint256 collateralClaim = (debt * markPrice) / collateralPrice; // mulDivDown
        uint256 liqBonus = (collateralClaim * LIQ_BONUS_WAD) / 1e18; // mulWadDown
        totalCollateralReturned = liqBonus + collateralClaim;
        // Cap to available collateral when underwater
        if (totalCollateralReturned > userCollateral.amount) totalCollateralReturned = userCollateral.amount;
        userCollateral.amount -= totalCollateralReturned;

        MockERC20(userCollateral.collateral).transfer(user, totalCollateralReturned);
    }
}

/// @notice Reduced LiquidityPool — hedge bookkeeping only (not this finding's focus).
contract LiquidityPool {
    uint256 public hedgedAmount;

    function liquidate(uint256 amount) external {
        hedgedAmount += amount;
    }
}

/// @notice Reduced Exchange._liquidate with the over-burn bug.
contract Exchange {
    ShortToken public immutable shortToken;
    ShortCollateral public immutable shortCollateral;
    LiquidityPool public immutable pool;
    MockERC20 public immutable powerPerp;
    MockERC20 public immutable collateralToken;

    constructor(ShortToken st, ShortCollateral sc, LiquidityPool p, MockERC20 pp, MockERC20 coll) {
        shortToken = st;
        shortCollateral = sc;
        pool = p;
        powerPerp = pp;
        collateralToken = coll;
    }

    function openShort(address trader, uint256 shortAmt, uint256 collAmt) external returns (uint256 id) {
        collateralToken.transferFrom(trader, address(shortCollateral), collAmt);
        id = shortToken.mintPosition(trader, address(collateralToken), shortAmt, collAmt);
        shortCollateral.collectCollateral(id, address(collateralToken), collAmt);
    }

    /// @dev Faithful reduction of Exchange._liquidate.
    function liquidate(uint256 positionId, uint256 debtRepaying) external {
        uint256 maxDebtRepayment = shortCollateral.maxLiquidatableDebt(positionId);
        require(maxDebtRepayment > 0);
        if (debtRepaying > maxDebtRepayment) debtRepaying = maxDebtRepayment;

        ShortToken.ShortPosition memory position = shortToken.getPosition(positionId);

        uint256 totalCollateralReturned = shortCollateral.liquidate(positionId, debtRepaying, msg.sender);

        address user = shortToken.ownerOf(positionId);

        uint256 finalPosition = position.shortAmount - debtRepaying;
        uint256 finalCollateralAmount = position.collateralAmount - totalCollateralReturned;

        shortToken.adjustPosition(positionId, user, position.collateral, finalPosition, finalCollateralAmount);

        pool.liquidate(debtRepaying);
        // @> VULN: burns full debtRepaying even when totalCollateralReturned was capped
        // below the collateral-equivalent of debtRepaying (underwater position).
        // FIX: burn only the powerPerp amount equivalent to collateral actually received.
        powerPerp.burn(msg.sender, debtRepaying);
    }
}

/// @dev Liquidator actor so msg.sender for liquidate is a distinct address.
contract Liquidator {
    Exchange public exchange;
    MockERC20 public powerPerp;

    constructor(Exchange ex, MockERC20 pp) {
        exchange = ex;
        powerPerp = pp;
    }

    function liquidate(uint256 positionId, uint256 debt) external {
        exchange.liquidate(positionId, debt);
    }
}

contract Exploit {
    MockERC20 public collateral; // CREATE nonce 1
    MockERC20 public powerPerp; // CREATE nonce 2
    ShortToken public shortToken; // CREATE nonce 3
    ShortCollateral public shortCollateral; // CREATE nonce 4
    LiquidityPool public pool; // CREATE nonce 5
    Exchange public exchange; // CREATE nonce 6
    Liquidator public liquidator; // CREATE nonce 7

    address public constant TRADER = address(0xA11CE);

    uint256 public constant SHORT_AMT = 1000e18;
    uint256 public constant COLL_AMT = 500e18; // only 500 collateral for 1000 short
    uint256 public constant DEBT_REPAYING = 1000e18;

    constructor() {
        collateral = new MockERC20("sUSD", "sUSD");
        powerPerp = new MockERC20("powerPerp", "pPWR");
        shortToken = new ShortToken();
        shortCollateral = new ShortCollateral(shortToken);
        pool = new LiquidityPool();
        exchange = new Exchange(shortToken, shortCollateral, pool, powerPerp, collateral);
        liquidator = new Liquidator(exchange, powerPerp);

        shortToken.setExchange(address(exchange));
        shortCollateral.setExchange(address(exchange));

        // Fund trader collateral and open an under-collateralized short (after crash).
        collateral.mint(address(this), COLL_AMT);
        collateral.approve(address(exchange), COLL_AMT);
        // openShort pulls from msg.sender — use this as trader proxy then reassign owner
        uint256 id = exchange.openShort(address(this), SHORT_AMT, COLL_AMT);
        // Crash collateral price: mark still 1e18, collateral now 0.25e18
        // claim = 1000 * 1 / 0.25 = 4000, +10% bonus = 4400 >> 500 available → capped to 500
        shortCollateral.setPrices(1e18, 0.25e18);

        // Fund liquidator with 1000 powerPerp to burn
        powerPerp.mint(address(liquidator), DEBT_REPAYING);
        id; // position id 1
        TRADER; // reserved label
    }

    function run() external {
        uint256 collBefore = collateral.balanceOf(address(liquidator));
        uint256 ppBefore = powerPerp.balanceOf(address(liquidator));
        require(ppBefore == DEBT_REPAYING, "liquidator not funded");

        // Liquidator repays full 1000 debt but position only has 500 collateral left.
        liquidator.liquidate(1, DEBT_REPAYING);

        uint256 collReceived = collateral.balanceOf(address(liquidator)) - collBefore;
        uint256 ppBurned = ppBefore - powerPerp.balanceOf(address(liquidator));

        // HARM: burned full 1000 powerPerp, received only 500 collateral (underwater cap).
        require(ppBurned == DEBT_REPAYING, "did not burn full debtRepaying");
        require(collReceived == COLL_AMT, "should receive all remaining collateral");
        require(collReceived < DEBT_REPAYING, "collateral received less than powerPerp burned");
        // Fair value of collateral at crashed price: 500 * 0.25 = 125 powerPerp-equivalent
        // Liquidator overpaid by 1000 - 500 (raw units) — the finding's concrete loss path.
        require(ppBurned > collReceived, "liquidator lost excess powerPerp");
    }
}
