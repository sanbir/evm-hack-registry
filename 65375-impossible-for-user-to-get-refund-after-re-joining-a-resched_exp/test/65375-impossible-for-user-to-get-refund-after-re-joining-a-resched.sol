// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Majority Protocol — re-join after leave keeps hasRefunded forever
    (Cyfrin / Dacian, 2026-01-27 majority-protocol-v2.0, #65375)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _payEntryFee never clears hasRefunded[gameId][player].
    Flow: join → reschedule → leaveRescheduledGame (refunds, sets
    hasRefunded=true) → re-join (pays again) → cancel →
    refundCancelledGame reverts AlreadyRefunded. Second fee permanently
    locked in SessionManager.

    Vulnerable path: _payEntryFee missing hasRefunded reset (@> VULN).
    Provenance: Engage-Protocol/engage-protocol @ cca0cb3
    Fixed: 3ac5654 (block rejoin if already refunded).
//////////////////////////////////////////////////////////////////////////*/

contract MockToken {
    string public constant name = "USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 18;
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

contract SessionManager {
    enum SessionState {
        Created,
        Ongoing,
        Ended,
        Cancelled,
        Concluded
    }

    struct GamePool {
        uint256 ticketPrice;
        uint256 totalCollectedAmount;
        address token;
    }

    struct Game {
        SessionState state;
        address creator;
        uint256 startTime;
        uint256 originalStartTime;
        uint256 numContestants;
    }

    mapping(uint256 => Game) public games;
    mapping(uint256 => GamePool) public gamePools;
    mapping(uint256 => mapping(address => bool)) public contestants;
    mapping(uint256 => mapping(address => bool)) public hasRefunded;
    uint256 public nextGameId = 1;
    uint256 public minimumRescheduleTime = 1 hours;

    error AlreadyRefunded(address player, uint256 gameId);
    error NotEnoughFunds(address token, uint256 amount);
    error NotJoined(address player, uint256 gameId);
    error GameIsNotRescheduled(uint256 gameId);

    function createGame(uint256 ticketPrice, address token, uint256 startTime) external returns (uint256 gameId) {
        gameId = nextGameId++;
        games[gameId] = Game({
            state: SessionState.Created,
            creator: msg.sender,
            startTime: startTime,
            originalStartTime: 0,
            numContestants: 0
        });
        gamePools[gameId] =
            GamePool({ticketPrice: ticketPrice, totalCollectedAmount: 0, token: token});
    }

    function joinGame(uint256 _gameId) external {
        require(
            games[_gameId].state == SessionState.Created || games[_gameId].state == SessionState.Ongoing,
            "bad state"
        );
        // FIX (3ac5654): require(!hasRefunded[_gameId][msg.sender], AlreadyRefunded(msg.sender, _gameId));
        _payEntryFee(_gameId, msg.sender);
        contestants[_gameId][msg.sender] = true;
        games[_gameId].numContestants++;
    }

    function rescheduleGame(uint256 _gameId, uint256 _newStartTime) external {
        require(games[_gameId].creator == msg.sender, "creator");
        require(games[_gameId].state == SessionState.Created, "created only");
        Game storage game = games[_gameId];
        require(_newStartTime > game.startTime + minimumRescheduleTime, "too soon");
        require(game.originalStartTime == 0, "already rescheduled");
        game.originalStartTime = game.startTime;
        game.startTime = _newStartTime;
    }

    function leaveRescheduledGame(uint256 _gameId) external {
        require(games[_gameId].state == SessionState.Created, "created");
        Game storage game = games[_gameId];
        require(game.originalStartTime != 0, GameIsNotRescheduled(_gameId));
        require(contestants[_gameId][msg.sender], NotJoined(msg.sender, _gameId));
        contestants[_gameId][msg.sender] = false;
        game.numContestants--;
        _refundEntryFee(_gameId, msg.sender);
    }

    function cancelGame(uint256 _gameId) external {
        require(games[_gameId].creator == msg.sender, "creator");
        games[_gameId].state = SessionState.Cancelled;
    }

    function refundCancelledGame(uint256 _gameId) external {
        require(games[_gameId].state == SessionState.Cancelled, "not cancelled");
        _refundEntryFee(_gameId, msg.sender);
    }

    /// @dev Missing reset of hasRefunded when player re-joins.
    function _payEntryFee(uint256 gameId, address player) internal {
        GamePool storage pool = gamePools[gameId];
        // FIX (recommended): if (hasRefunded[gameId][player]) hasRefunded[gameId][player] = false;
        MockToken(pool.token).transferFrom(player, address(this), pool.ticketPrice); // @> VULN: pays fee but never clears hasRefunded
        pool.totalCollectedAmount += pool.ticketPrice;
    }

    function _refundEntryFee(uint256 gameId, address player) internal {
        GamePool storage pool = gamePools[gameId];
        require(pool.totalCollectedAmount >= pool.ticketPrice, NotEnoughFunds(pool.token, pool.totalCollectedAmount));
        require(!hasRefunded[gameId][player], AlreadyRefunded(player, gameId));
        hasRefunded[gameId][player] = true;
        MockToken(pool.token).transfer(player, pool.ticketPrice);
        pool.totalCollectedAmount -= pool.ticketPrice;
    }
}

/// @dev Player actor so refunds/joins use a non-Exploit address (hasRefunded keyed by player).
contract Player {
    MockToken public tok;
    SessionManager public sm;

    constructor(MockToken _tok, SessionManager _sm) {
        tok = _tok;
        sm = _sm;
    }

    function doJoin(uint256 gameId, uint256 fee) external {
        tok.approve(address(sm), fee);
        sm.joinGame(gameId);
    }

    function doLeave(uint256 gameId) external {
        sm.leaveRescheduledGame(gameId);
    }

    function doRefund(uint256 gameId) external {
        sm.refundCancelledGame(gameId);
    }

    function tryRefund(uint256 gameId) external returns (bool ok) {
        try sm.refundCancelledGame(gameId) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    MockToken public tok; // CREATE 1
    SessionManager public sm; // CREATE 2
    Player public player; // CREATE 3

    uint256 public constant FEE = 10 ether;
    uint256 public constant GAME_ID = 1;

    constructor() {
        tok = new MockToken();
        sm = new SessionManager();
        player = new Player(tok, sm);
    }

    function run() external {
        // create game with startTime far enough for reschedule window
        uint256 startTime = block.timestamp + 2 days;
        sm.createGame(FEE, address(tok), startTime);

        // user joins (first fee)
        tok.mint(address(player), FEE * 2);
        player.doJoin(GAME_ID, FEE);
        require(tok.balanceOf(address(sm)) == FEE, "after join");
        require(tok.balanceOf(address(player)) == FEE, "player leftover");

        // reschedule
        sm.rescheduleGame(GAME_ID, startTime + sm.minimumRescheduleTime() + 1);

        // leave → refunded, hasRefunded=true
        player.doLeave(GAME_ID);
        require(tok.balanceOf(address(player)) == FEE * 2, "refunded first fee");
        require(tok.balanceOf(address(sm)) == 0, "sm empty after leave");
        require(sm.hasRefunded(GAME_ID, address(player)), "flag set");

        // re-join (pays second fee) — hasRefunded still true
        player.doJoin(GAME_ID, FEE);
        require(tok.balanceOf(address(sm)) == FEE, "second fee locked in");
        require(tok.balanceOf(address(player)) == FEE, "player paid again");
        require(sm.hasRefunded(GAME_ID, address(player)), "flag still set - VULN");

        // cancel
        sm.cancelGame(GAME_ID);

        // refund reverts AlreadyRefunded — second fee permanently stuck
        bool ok = player.tryRefund(GAME_ID);
        require(!ok, "refund should fail");
        require(tok.balanceOf(address(sm)) == FEE, "fee stuck in SessionManager");
        require(tok.balanceOf(address(player)) == FEE, "player cannot recover second fee");
    }
}
