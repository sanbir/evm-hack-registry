// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  GMX Synthetics — H-5 ADL orders have no slippage protection
    (Sherlock 2023-02-gmx, finding 18631).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: AdlUtils.createAdlOrder builds a MarketDecrease whose
    acceptablePrice is 0 for a long (uint256 max for a short) and whose
    minOutputAmount is 0. DecreasePositionCollateralUtils caps the execution
    price at MAX_POSITION_IMPACT_FACTOR, then still subtracts the uncapped
    excess (priceImpactDiffUsd) from the trader's profit. When that profit
    covers the diff, adjustedPriceImpactDiffUsd is set to 0, so the haircut
    is not claimable. AdlHandler only checks that the pool's pnl factor fell.

    Numbers (18-decimal USDC):
      entry 1000, oracle 2000, size 10000, collateral 2000
      raw negative impact 7000, cap 1000, priceImpactDiff 6000
      capped execution price 1800, pnl at that price 8000
      stated minimum = collateral + capped pnl = 10000
      vulnerable payout = (8000 - 6000) + 2000 = 4000
      the pool keeps the 6000 difference

    The control stores minOutputAmount = 10000, so the 4000 fill is refused,
    then charges only the 1000 cap and pays the 10000 minimum. */

contract Usdc {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 18;
    address public minter;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor() {
        minter = msg.sender;
    }

    function setMinter(address next) external {
        require(msg.sender == minter, "minter");
        minter = next;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AdlUtils {
    enum OrderType {
        MarketSwap,
        LimitSwap,
        MarketIncrease,
        LimitIncrease,
        MarketDecrease,
        LimitDecrease,
        StopLossDecrease,
        Liquidation
    }

    enum DecreasePositionSwapType {
        NoSwap,
        SwapPnlTokenToCollateralToken,
        SwapCollateralTokenToPnlToken
    }

    struct Numbers {
        OrderType orderType;
        DecreasePositionSwapType decreasePositionSwapType;
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 triggerPrice;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 callbackGasLimit;
        uint256 minOutputAmount;
        uint256 updatedAtBlock;
    }

    struct Position {
        uint256 sizeInUsd;
        uint256 collateral;
        bool isLong;
    }

    uint256 public constant ENTRY_PRICE = 1_000 ether;
    uint256 public constant ORACLE_PRICE = 2_000 ether;
    uint256 public constant SIZE_USD = 10_000 ether;
    uint256 public constant COLLATERAL = 2_000 ether;
    uint256 public constant RAW_IMPACT = 7_000 ether;
    uint256 public constant IMPACT_CAP = 1_000 ether;

    Usdc public token;
    mapping(address => Position) public positions;
    Numbers public order;

    uint256 public storedAcceptablePrice;
    uint256 public storedMinOutput;
    uint256 public statedMinimum;
    uint256 public cappedPrice;
    uint256 public pnlAtCap;
    uint256 public priceImpactDiff;
    uint256 public adjustedPnl;
    uint256 public outputAmount;
    uint256 public paidToUser;
    bool public priceAccepted;
    bool public controlBlocked;
    bool public poolPnlFactorFell;

    constructor(Usdc _token) {
        token = _token;
    }

    function executionPrice(uint256 impactUsd) public pure returns (uint256) {
        return ORACLE_PRICE * (SIZE_USD - impactUsd) / SIZE_USD;
    }

    function pnlAt(uint256 price) public pure returns (uint256) {
        return SIZE_USD * (price - ENTRY_PRICE) / ENTRY_PRICE;
    }

    function openLong(address account) external {
        require(positions[account].sizeInUsd == 0, "open");
        positions[account] = Position({sizeInUsd: SIZE_USD, collateral: COLLATERAL, isLong: true});
        uint256 price = executionPrice(IMPACT_CAP);
        uint256 pnl = pnlAt(price);
        statedMinimum = COLLATERAL + pnl;
        token.mint(address(this), COLLATERAL);
    }

    // Audited AdlUtils.createAdlOrder. The two blamed expressions are the
    // acceptablePrice ternary and the zero minOutputAmount.
    function createAdlOrder(address account, uint256 sizeDeltaUsd, uint256 updatedAtBlock) external {
        Position memory position = positions[account];
        require(position.sizeInUsd >= sizeDeltaUsd && sizeDeltaUsd != 0, "size");

        uint256 acceptablePrice;
        // @> VULN: long ADL sets acceptablePrice to 0; short ADL sets it to uint256 max
        acceptablePrice = position.isLong ? 0 : type(uint256).max;
        storedAcceptablePrice = acceptablePrice;
        // @> VULN: minOutputAmount is forced to 0, so the payout has no floor
        storedMinOutput = 0;

        Numbers memory numbers = Numbers(
            OrderType.MarketDecrease,
            DecreasePositionSwapType.NoSwap,
            sizeDeltaUsd,
            0,
            0,
            acceptablePrice,
            0,
            0,
            storedMinOutput,
            updatedAtBlock
        );
        order = numbers;
    }

    // Control order: same position, but the minimum is the capped-impact payout.
    function createAdlOrderAtMinimum(address account, uint256 minimum) external {
        Position memory position = positions[account];
        require(position.sizeInUsd == SIZE_USD, "size");
        require(minimum == statedMinimum && minimum != 0, "minimum");
        storedAcceptablePrice = executionPrice(IMPACT_CAP);
        storedMinOutput = minimum;
        order = Numbers(
            OrderType.MarketDecrease,
            DecreasePositionSwapType.NoSwap,
            SIZE_USD,
            0,
            0,
            storedAcceptablePrice,
            0,
            0,
            storedMinOutput,
            1
        );
    }

    function executeAdl(address account) external returns (uint256 paid) {
        Position memory position = positions[account];
        require(position.sizeInUsd == SIZE_USD && position.isLong, "position");

        cappedPrice = executionPrice(IMPACT_CAP);
        bool accepted = cappedPrice >= storedAcceptablePrice;
        require(accepted, "price");
        priceAccepted = true;

        pnlAtCap = pnlAt(cappedPrice);
        priceImpactDiff = RAW_IMPACT - IMPACT_CAP;
        adjustedPnl = pnlAtCap - priceImpactDiff;
        outputAmount = adjustedPnl + position.collateral;

        if (storedMinOutput != 0 && outputAmount < storedMinOutput) {
            controlBlocked = true;
            return 0;
        }

        token.mint(address(this), pnlAtCap);
        paidToUser = outputAmount;
        token.transfer(account, paidToUser);
        positions[account].sizeInUsd = 0;
        positions[account].collateral = 0;
        // AdlHandler only checks that the pool pnl factor fell. It does not
        // compare paidToUser with statedMinimum.
        poolPnlFactorFell = true;
        return paidToUser;
    }

    // Recommended MAX_POSITION_IMPACT_FACTOR_FOR_ADL: charge the cap only.
    function executeCappedAdl(address account) external returns (uint256 paid) {
        Position memory position = positions[account];
        require(position.sizeInUsd == SIZE_USD, "position");
        uint256 price = executionPrice(IMPACT_CAP);
        uint256 pnl = pnlAt(price);
        uint256 payout = position.collateral + pnl;
        require(payout >= statedMinimum, "floor");
        token.mint(address(this), pnl);
        token.transfer(account, payout);
        positions[account].sizeInUsd = 0;
        positions[account].collateral = 0;
        paidToUser = payout;
        return payout;
    }
}

contract Exploit {
    address public constant TRADER = 0x2222222222222222222222222222222222222222;

    Usdc public token;
    AdlUtils public market;

    uint256 public traderReceived;
    uint256 public statedMinimum;
    uint256 public poolRetained;
    uint256 public acceptablePrice;
    uint256 public minOutputAmount;
    bool public controlBlocked;
    uint256 public controlPaid;

    constructor() {
        token = new Usdc();
        market = new AdlUtils(token);
        token.setMinter(address(market));
    }

    function run() external {
        market.openLong(TRADER);
        uint256 minimum = market.statedMinimum();
        market.createAdlOrder(TRADER, market.SIZE_USD(), 1);
        uint256 received = market.executeAdl(TRADER);
        uint256 retained = token.balanceOf(address(market));

        require(market.storedAcceptablePrice() == 0, "price");
        require(market.storedMinOutput() == 0, "min");
        require(market.priceAccepted(), "accepted");
        require(minimum == 10_000 ether, "minimum");
        require(received == 4_000 ether, "received");
        require(received < minimum, "worse");
        require(retained == minimum - received, "gap");
        require(token.balanceOf(TRADER) == received, "trader");
        require(market.poolPnlFactorFell(), "global");

        traderReceived = received;
        statedMinimum = minimum;
        poolRetained = retained;
        acceptablePrice = market.storedAcceptablePrice();
        minOutputAmount = market.storedMinOutput();
    }

    function runControl() external {
        market.openLong(TRADER);
        uint256 minimum = market.statedMinimum();
        market.createAdlOrderAtMinimum(TRADER, minimum);
        uint256 blocked = market.executeAdl(TRADER);
        require(blocked == 0, "bad fill");
        require(market.controlBlocked(), "not blocked");
        require(token.balanceOf(TRADER) == 0, "paid");
        uint256 capped = market.executeCappedAdl(TRADER);
        require(capped == minimum, "below minimum");
        require(token.balanceOf(TRADER) == minimum, "trader");
        require(token.balanceOf(address(market)) == 0, "pool");
        controlBlocked = true;
        controlPaid = capped;
    }
}
