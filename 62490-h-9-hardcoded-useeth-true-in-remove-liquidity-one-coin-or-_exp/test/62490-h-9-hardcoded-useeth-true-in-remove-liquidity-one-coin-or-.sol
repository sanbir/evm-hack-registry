// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  Notional Exponent H-9 — hardcoded `use_eth = true` on Curve V2 pool exit
//  (sherlock 2025-06-notional-exponent, CurveConvex2Token.sol @ main).
//
//  ENTER computes use_eth dynamically: add_liquidity(..., 0 < msgValue). A vault
//  whose primary token is WETH (not native ETH) enters with msgValue == 0, so
//  use_eth == false and the pool pulls WETH. Correct.
//
//  EXIT hardcodes use_eth = true:
//    remove_liquidity_one_coin(poolClaim, _PRIMARY_INDEX, minAmt, true, address(this))
//  When the pool's primary coin is WETH (ETH_INDEX == primary), use_eth == true
//  makes the pool UNWRAP WETH → native ETH and send ETH to the vault. The vault
//  entered with WETH and has no way to receive native ETH → the transfer reverts
//  → the position can never be exited → funds are permanently stuck.
//
//  _enterPool / _exitPool are reproduced VERBATIM (marked @>).
// =============================================================================

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

/*//////////////////////////////////////////////////////////////
        WETH — deposit/withdraw wrap of native ETH
//////////////////////////////////////////////////////////////*/
contract WETH {
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amt) external {
        balanceOf[msg.sender] -= amt;
        (bool ok,) = msg.sender.call{value: amt}("");
        require(ok, "ETH send failed");
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/*//////////////////////////////////////////////////////////////
   Minimal Curve V2 two-token pool. coin0 = WETH (ETH_INDEX = 0).
   On remove with use_eth == true, the pool unwraps WETH and sends
   NATIVE ETH to the receiver (Curve V2 semantics).
//////////////////////////////////////////////////////////////*/
contract CurveV2Pool {
    WETH public immutable weth; // coin0
    uint256 public constant ETH_INDEX = 0;
    mapping(address => uint256) public lp; // LP balance
    uint256 public totalLp;

    constructor(WETH _weth) {
        weth = _weth;
    }

    // Single-sided WETH deposit (use_eth == false → pull WETH). Mints LP 1:1.
    function add_liquidity(uint256[2] memory amounts, uint256, /*minMint*/ bool use_eth)
        external
        payable
        returns (uint256 minted)
    {
        uint256 amt = amounts[0];
        if (use_eth) {
            require(msg.value == amt, "incorrect eth amount");
        } else {
            weth.transferFrom(msg.sender, address(this), amt); // pull WETH
        }
        minted = amt;
        lp[msg.sender] += minted;
        totalLp += minted;
    }

    function remove_liquidity_one_coin(
        uint256 poolClaim,
        uint256, /*i*/
        uint256, /*minAmt*/
        bool use_eth,
        address receiver
    ) external returns (uint256 out) {
        lp[msg.sender] -= poolClaim;
        totalLp -= poolClaim;
        out = poolClaim; // 1:1 for the single LP holder
        if (use_eth) {
            // Unwrap WETH → native ETH and send ETH to the receiver.
            weth.withdraw(out);
            (bool ok,) = receiver.call{value: out}("");
            require(ok, "eth transfer failed"); // reverts if receiver rejects ETH
        } else {
            weth.transfer(receiver, out);
        }
    }

    receive() external payable {}
}

interface ICurve2TokenPoolV2 {
    function add_liquidity(uint256[2] memory amounts, uint256 minMint, bool use_eth) external payable returns (uint256);
    function remove_liquidity_one_coin(uint256 poolClaim, uint256 i, uint256 minAmt, bool use_eth, address receiver)
        external
        returns (uint256);
}

/*//////////////////////////////////////////////////////////////
   Notional CurveConvex2Token (V2 path). _enterPool computes use_eth
   dynamically; _exitPool HARDCODES use_eth = true. No receive() → a
   WETH vault cannot accept the native ETH the pool sends on exit.
//////////////////////////////////////////////////////////////*/
contract CurveConvex2Token {
    address public immutable CURVE_POOL;
    WETH public immutable TOKEN_1; // primary = WETH
    uint256 internal constant _PRIMARY_INDEX = 0;

    constructor(address pool, WETH weth) {
        CURVE_POOL = pool;
        TOKEN_1 = weth;
    }

    function _enterPool(uint256[] memory _amounts, uint256 minPoolClaim, uint256 msgValue)
        internal
        returns (uint256)
    {
        uint256[2] memory amounts;
        amounts[0] = _amounts[0];
        amounts[1] = _amounts[1];
        // @> V2: use_eth = true if msgValue > 0. A WETH vault enters with msgValue == 0
        // @> → use_eth == false → the pool pulls WETH (correct).
        return ICurve2TokenPoolV2(CURVE_POOL).add_liquidity{value: msgValue}(amounts, minPoolClaim, 0 < msgValue);
    }

    function _exitPool(uint256 poolClaim, uint256[] memory _minAmounts) internal returns (uint256 exitBalance) {
        // @> BUG: use_eth is HARDCODED to true, even though the vault entered with WETH.
        // @> The pool unwraps WETH and sends NATIVE ETH here, which this WETH vault
        // @> cannot receive → the exit reverts → funds are stuck.
        exitBalance = ICurve2TokenPoolV2(CURVE_POOL).remove_liquidity_one_coin(
            poolClaim, _PRIMARY_INDEX, _minAmounts[_PRIMARY_INDEX], true, address(this)
        );
    }

    // Deposit WETH → enter the pool single-sided.
    function deposit(uint256 wethAmount) external {
        TOKEN_1.transferFrom(msg.sender, address(this), wethAmount);
        TOKEN_1.approve(CURVE_POOL, wethAmount);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = wethAmount;
        _enterPool(amounts, 0, 0); // msgValue = 0 (WETH, not native ETH)
    }

    // Withdraw the full position (single-sided exit).
    function withdraw(uint256 poolClaim) external returns (uint256) {
        uint256[] memory minAmounts = new uint256[](2);
        return _exitPool(poolClaim, minAmounts);
    }

    // NOTE: no receive() / fallback — a WETH vault does not accept native ETH.
}

/*//////////////////////////////////////////////////////////////
   CurveConvex2TokenFixed — mitigation: exit with use_eth = false
   (symmetric with entry), so the pool returns WETH and withdrawal
   succeeds.
//////////////////////////////////////////////////////////////*/
contract CurveConvex2TokenFixed {
    address public immutable CURVE_POOL;
    WETH public immutable TOKEN_1;
    uint256 internal constant _PRIMARY_INDEX = 0;

    constructor(address pool, WETH weth) {
        CURVE_POOL = pool;
        TOKEN_1 = weth;
    }

    function deposit(uint256 wethAmount) external {
        TOKEN_1.transferFrom(msg.sender, address(this), wethAmount);
        TOKEN_1.approve(CURVE_POOL, wethAmount);
        uint256[2] memory amounts;
        amounts[0] = wethAmount;
        ICurve2TokenPoolV2(CURVE_POOL).add_liquidity(amounts, 0, false);
    }

    function withdraw(uint256 poolClaim) external returns (uint256) {
        // FIX: use_eth = false → pool returns WETH.
        return ICurve2TokenPoolV2(CURVE_POOL).remove_liquidity_one_coin(
            poolClaim, _PRIMARY_INDEX, 0, false, address(this)
        );
    }
}

/*//////////////////////////////////////////////////////////////
   STUCK marker — non-fund harm probe: minted equal to the locked
   WETH so the Playground can measure the magnitude of stuck funds.
//////////////////////////////////////////////////////////////*/
contract StuckMarker {
    string public symbol = "STUCK-WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — a WETH depositor's position becomes permanently stuck:
   entry (use_eth=false) works, but withdrawal (hardcoded use_eth=true)
   reverts because the pool sends native ETH to the WETH vault.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // stuck-funds probe sink

    uint256 internal constant DEPOSIT = 10 ether;

    WETH public weth;
    CurveV2Pool public pool;
    CurveConvex2Token public vault;
    StuckMarker public stuck;

    function run() external payable {
        weth = new WETH();
        pool = new CurveV2Pool(weth);
        vault = new CurveConvex2Token(address(pool), weth);
        stuck = new StuckMarker();

        // Fund a depositor with WETH and deposit into the vault (enters the pool with WETH).
        weth.deposit{value: DEPOSIT}(); // this contract holds DEPOSIT WETH
        weth.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT);

        // Try to withdraw: the hardcoded use_eth=true makes the pool send native ETH
        // to the WETH vault, which reverts → the position is permanently stuck.
        try vault.withdraw(DEPOSIT) returns (uint256) {
            // no-op: with the bug this path is not reached
        } catch {
            // Withdrawal reverted → DEPOSIT WETH is locked in the vault's LP position.
            stuck.mint(SINK, DEPOSIT);
        }
    }

    receive() external payable {}
}
