// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Majority Protocol finding 65376:
// "DepositManager::getRewards always includes REFERRER_FEE resulting in 2% of
//  every game's rewards not being distributed when there were no referrers".
//
// Real audited source: github.com/Engage-Protocol/engage-protocol
//   src/DepositManager.sol @ e090f2e~1  (the pre-fix / audited state).
//   The fix commit is e090f2e (which added the CLAIMER_ROLE + totalReferralRewards
//   bookkeeping); its PARENT is the vulnerable state reproduced here.
//
// getRewards ALWAYS subtracts REFERRER_FEE (200 bp = 2%) from the pool when
// computing the winner's reward — even for games that had no referrers. That 2%
// is never handed to the winner. Meanwhile _payEntryFee accrues the same 2% of
// each ticket into referralRewards[gameId][referrer]; with no referrer that
// referrer is address(0), which has no claimer (sibling finding 65372). The net
// result: 2% of every game's collected amount is permanently stranded inside
// DepositManager — withheld from the winner AND unclaimable by anyone.
//
// Harm asserted: after the winner, creator and protocol take their full, correct
// slices, the DepositManager token balance == totalCollectedAmount * REFERRER_FEE
// / BASIS_POINTS (2%) > 0, with no withdrawal path. The 2% equals exactly the
// referral owed to address(0), which no account can claim.
//
// Negative control (driver): the corrected getRewards that omits REFERRER_FEE
// hands the winner the full non-fee share, so the residual balance is 0.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for the opaque game token (an ERC20). The real
///      contract uses SafeERC20 over an arbitrary IERC20; only the token itself
///      is a boundary, never the vulnerable DepositManager logic.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
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

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. getRewards is inlined VERBATIM from the audited pre-fix
// DepositManager (e090f2e~1). The surrounding GamePool struct, constants and the
// deposit / fee / reward / referral paths are reproduced faithfully from the same
// source (SafeERC20 -> MiniToken, Registry referrer lookup -> explicit referrer
// argument where address(0) means "no referrer", the SessionManagerBase /
// AccessControl scaffolding dropped as out-of-scope boundary).
// ─────────────────────────────────────────────────────────────────────────────
contract DepositManagerBuggy {
    struct GamePool {
        uint256 gameId;
        uint256 ticketPrice;
        uint256 creatorFee;
        uint256 protocolFee;
        uint256 totalCollectedAmount;
        address token;
        bool feesPaid;
    }

    mapping(uint256 gameId => GamePool pool) public gamePools;
    mapping(uint256 gameId => mapping(address player => bool)) public hasClaimed;
    mapping(uint256 sessionId => mapping(address referrer => uint256 referralReward)) public referralRewards;

    uint256 public protocolFee = 500;
    uint256 public maxCreatorFee = 1000;
    uint256 public constant REFERRER_FEE = 200;
    uint256 public constant MAX_GAME_FEES = 3000;
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * @notice Calculates the total rewards available for distribution to winners
     * @param gameId The ID of the session
     * @return The amount of tokens available for rewards after deducting fees
     */
    function getRewards(uint256 gameId) public view returns (uint256) {
        return gamePools[gameId].totalCollectedAmount
            * (BASIS_POINTS - (gamePools[gameId].creatorFee + gamePools[gameId].protocolFee + REFERRER_FEE)) / BASIS_POINTS; // @> REFERRER_FEE is subtracted unconditionally, even when the game had no referrers, so 2% of the pool is never paid to the winner and is stranded
    }

    // ── faithful reproduction of _createGamePool ──
    function createGamePool(uint256 gameId, uint256 _ticketPrice, uint256 _creatorFee, address _token) external {
        require(_creatorFee <= maxCreatorFee, "InvalidCreatorFee");
        gamePools[gameId] = GamePool({
            gameId: gameId,
            ticketPrice: _ticketPrice,
            creatorFee: _creatorFee,
            protocolFee: protocolFee,
            totalCollectedAmount: 0,
            token: _token,
            feesPaid: false
        });
    }

    // ── faithful reproduction of _payEntryFee (Registry lookup -> referrer arg;
    //    no referrer => address(0), matching Registry(registry).referrers(player)) ──
    function payEntryFee(uint256 gameId, address referrer) external {
        GamePool storage pool = gamePools[gameId];
        require(MiniToken(pool.token).balanceOf(msg.sender) >= pool.ticketPrice, "InsufficientBalance");
        pool.totalCollectedAmount += pool.ticketPrice;
        referralRewards[gameId][referrer] += pool.ticketPrice * REFERRER_FEE;
        MiniToken(pool.token).transferFrom(msg.sender, address(this), pool.ticketPrice);
    }

    // ── faithful reproduction of _claimReferralReward (address(0) can never call) ──
    function claimReferralReward(uint256 gameId) external {
        uint256 referralReward = referralRewards[gameId][msg.sender] / BASIS_POINTS;
        referralRewards[gameId][msg.sender] = 0;
        MiniToken(gamePools[gameId].token).transfer(msg.sender, referralReward);
    }

    // ── faithful reproduction of _distributeFees ──
    function distributeFees(uint256 gameId, address creator, address protocolTreasury) external {
        GamePool storage pool = gamePools[gameId];
        require(!pool.feesPaid, "FeesAlreadyPaid");
        pool.feesPaid = true;
        MiniToken(pool.token).transfer(creator, pool.totalCollectedAmount * pool.creatorFee / BASIS_POINTS);
        MiniToken(pool.token).transfer(protocolTreasury, pool.totalCollectedAmount * pool.protocolFee / BASIS_POINTS);
    }

    // ── faithful reproduction of _distributeRewards ──
    function distributeRewards(uint256 gameId, address winner, uint256 reward) external {
        require(!hasClaimed[gameId][winner], "AlreadyClaimed");
        require(reward != 0, "NoRewardAvailable");
        hasClaimed[gameId][winner] = true;
        MiniToken(gamePools[gameId].token).transfer(winner, reward);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control). Identical to DepositManagerBuggy except
// getRewards OMITS REFERRER_FEE: with no referrers, the referral slice belongs to
// the prize pool and is handed to the winner, so nothing is stranded.
// ─────────────────────────────────────────────────────────────────────────────
contract DepositManagerFixed {
    struct GamePool {
        uint256 gameId;
        uint256 ticketPrice;
        uint256 creatorFee;
        uint256 protocolFee;
        uint256 totalCollectedAmount;
        address token;
        bool feesPaid;
    }

    mapping(uint256 gameId => GamePool pool) public gamePools;
    mapping(uint256 gameId => mapping(address player => bool)) public hasClaimed;
    mapping(uint256 sessionId => mapping(address referrer => uint256 referralReward)) public referralRewards;

    uint256 public protocolFee = 500;
    uint256 public maxCreatorFee = 1000;
    uint256 public constant REFERRER_FEE = 200;
    uint256 public constant MAX_GAME_FEES = 3000;
    uint256 public constant BASIS_POINTS = 10000;

    function getRewards(uint256 gameId) public view returns (uint256) {
        // FIX: do not deduct REFERRER_FEE when there were no referrers.
        return gamePools[gameId].totalCollectedAmount
            * (BASIS_POINTS - (gamePools[gameId].creatorFee + gamePools[gameId].protocolFee)) / BASIS_POINTS;
    }

    function createGamePool(uint256 gameId, uint256 _ticketPrice, uint256 _creatorFee, address _token) external {
        require(_creatorFee <= maxCreatorFee, "InvalidCreatorFee");
        gamePools[gameId] = GamePool({
            gameId: gameId,
            ticketPrice: _ticketPrice,
            creatorFee: _creatorFee,
            protocolFee: protocolFee,
            totalCollectedAmount: 0,
            token: _token,
            feesPaid: false
        });
    }

    function payEntryFee(uint256 gameId, address referrer) external {
        GamePool storage pool = gamePools[gameId];
        require(MiniToken(pool.token).balanceOf(msg.sender) >= pool.ticketPrice, "InsufficientBalance");
        pool.totalCollectedAmount += pool.ticketPrice;
        referralRewards[gameId][referrer] += pool.ticketPrice * REFERRER_FEE;
        MiniToken(pool.token).transferFrom(msg.sender, address(this), pool.ticketPrice);
    }

    function distributeFees(uint256 gameId, address creator, address protocolTreasury) external {
        GamePool storage pool = gamePools[gameId];
        require(!pool.feesPaid, "FeesAlreadyPaid");
        pool.feesPaid = true;
        MiniToken(pool.token).transfer(creator, pool.totalCollectedAmount * pool.creatorFee / BASIS_POINTS);
        MiniToken(pool.token).transfer(protocolTreasury, pool.totalCollectedAmount * pool.protocolFee / BASIS_POINTS);
    }

    function distributeRewards(uint256 gameId, address winner, uint256 reward) external {
        require(!hasClaimed[gameId][winner], "AlreadyClaimed");
        require(reward != 0, "NoRewardAvailable");
        hasClaimed[gameId][winner] = true;
        MiniToken(gamePools[gameId].token).transfer(winner, reward);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: N players join a game with NO referrers. The buggy getRewards
// pays the winner only 88% (100% - 5% creator - 5% protocol - 2% referrer),
// while the creator and protocol take their 5% each. The final 2% is accrued to
// address(0) as an unclaimable referral and remains locked in the contract. The
// locked magnitude is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant WINNER = 0x1111111111111111111111111111111111111111;
    address internal constant CREATOR = 0x0000000000000000000000000000000000000C0C;
    address internal constant PROTOCOL = 0x0000000000000000000000000000000000000d01;

    uint256 internal constant GAME = 1;
    uint256 internal constant TICKET = 100 ether;
    uint256 internal constant PLAYERS = 10;
    uint256 internal constant CREATOR_FEE = 500; // 5% (protocolFee defaults to 500 = 5%)

    // Exposed results (asserted by the driver).
    uint256 public totalPool;
    uint256 public winnerReward;
    uint256 public buggyResidual;
    uint256 public lockedReferral;
    uint256 public sinkMarkerBalance;
    address public managerAddr;
    address public vulnAddr;
    address public markerAddr;
    address public tokenAddr;

    MiniToken internal token;
    DepositManagerBuggy internal mgr;
    MiniToken internal marker;

    constructor() {
        // fixed deploy order (index 0 first): token, vulnerable manager, marker
        token = new MiniToken("Game", "GAME");
        mgr = new DepositManagerBuggy();
        marker = new MiniToken("Marker", "MARK");

        managerAddr = address(mgr);
        vulnAddr = address(mgr);
        markerAddr = address(marker);
        tokenAddr = address(token);

        // create the game (5% creator fee; protocolFee defaults to 5%)
        mgr.createGamePool(GAME, TICKET, CREATOR_FEE, address(token));

        // fund this contract to act as every joining player and approve the pool
        token.mint(address(this), TICKET * PLAYERS);
        token.approve(address(mgr), type(uint256).max);

        // PLAYERS players join, NONE with a referrer -> referral accrues to address(0)
        for (uint256 i = 0; i < PLAYERS; i++) {
            mgr.payEntryFee(GAME, address(0));
        }
        totalPool = TICKET * PLAYERS; // 1000 ether collected
    }

    function run() external payable {
        // --- distribute rewards through the REAL buggy path ---
        winnerReward = mgr.getRewards(GAME);            // buggy: 88% of pool = 880 ether
        mgr.distributeRewards(GAME, WINNER, winnerReward);
        mgr.distributeFees(GAME, CREATOR, PROTOCOL);    // creator 5% + protocol 5%

        // --- harm: 2% of the pool is stranded, unclaimable ---
        buggyResidual = token.balanceOf(address(mgr));
        // the stranded amount is exactly the referral owed to address(0) (unclaimable)
        lockedReferral = mgr.referralRewards(GAME, address(0)) / mgr.BASIS_POINTS();

        uint256 expectedLock = totalPool * mgr.REFERRER_FEE() / mgr.BASIS_POINTS(); // 2%
        require(buggyResidual == expectedLock, "residual must equal REFERRER_FEE slice");
        require(buggyResidual > 0, "no funds stranded");
        require(lockedReferral == buggyResidual, "stranded amount != address(0) referral");

        // record the locked magnitude on the marker at the SINK
        marker.mint(SINK, buggyResidual);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
