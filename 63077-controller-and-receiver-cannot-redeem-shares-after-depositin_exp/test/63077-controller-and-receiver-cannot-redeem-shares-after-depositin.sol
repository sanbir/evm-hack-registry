// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Superform v2-Periphery finding 63077
// (Spearbit, MiloTruck — HIGH):
//   "Controller and receiver cannot redeem shares after depositing fund if the
//    receiver address differs."
//
// SuperVault.deposit mints the ERC20 shares to `receiver`, but records the
// SuperVaultStrategy cost-basis state (accumulatorShares / accumulatorCostBasis)
// under the *controller* (msg.sender). When receiver != controller nobody can
// ever redeem the deposit:
//   * the RECEIVER holds the shares but has an EMPTY strategy state, so the
//     redeem-fulfilment path reverts INSUFFICIENT_SHARES inside
//     `_calculateCostBasis` (`requestedShares > state.accumulatorShares`);
//   * the CONTROLLER holds the state but has NO shares to move to escrow, so it
//     cannot even open a redeem request.
// The deposited assets are therefore permanently locked in the vault.
//
// VERBATIM audited source reproduced unchanged below:
//   * the vulnerable deposit call-site (state keyed to msg.sender, shares minted
//     to receiver) — marked `// @>`;
//   * `SuperVaultStrategy._calculateCostBasis` (the function that reverts).
// `handleOperation`'s body is not embedded in the finding (only its call-site
// and `_calculateCostBasis` are verbatim); it is reconstructed minimally per the
// finding's described controller-vs-receiver attribution. The vulnerable
// boundary itself is NOT mocked — the real buggy logic runs.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin's Math (floor mulDiv + Rounding),
///      exactly the surface `_calculateCostBasis` uses (`x.mulDiv(y, d, Rounding.Floor)`).
library Math {
    enum Rounding {
        Floor,
        Ceil,
        Trunc,
        Expand
    }

    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding) internal pure returns (uint256) {
        return x * y / denominator;
    }
}

/// @dev Minimal ERC20 double. Used both for the vault asset (USDC) and for the
///      LOCKED-USDC harm marker minted to the SINK.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
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

interface ISuperVaultStrategy {
    // The audited enum had a `Deposit` member used by the deposit call-site.
    enum Operation {
        Deposit,
        Redeem
    }

    function handleOperation(
        address controller,
        address receiver,
        uint256 assets,
        uint256 shares,
        Operation op
    ) external;

    // Reconstruction helpers (not part of the verbatim finding surface).
    function handleRedeem(address controller, uint256 shares) external returns (uint256 costBasis);
    function getState(address controller) external view returns (uint256 accShares, uint256 accCostBasis);
    function initialize(address vault) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE strategy. Holds the per-controller cost-basis accounting and the
// VERBATIM `_calculateCostBasis`. `handleOperation(Deposit)` credits the state to
// the CONTROLLER exactly as the finding describes.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVaultStrategy is ISuperVaultStrategy {
    using Math for uint256;

    // Audited struct fields referenced by the verbatim `_calculateCostBasis`.
    struct SuperVaultState {
        uint256 accumulatorShares;
        uint256 accumulatorCostBasis;
    }

    mapping(address controller => SuperVaultState state) private superVaultState;

    error INSUFFICIENT_SHARES();
    error ONLY_VAULT();

    address public vault;

    function initialize(address _vault) external {
        require(vault == address(0), "init");
        vault = _vault;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert ONLY_VAULT();
        _;
    }

    /// @notice Reconstructed minimally (body not embedded in the finding): on a
    ///         Deposit, the accumulator shares/cost-basis are credited to the
    ///         `controller`. The vault passes msg.sender as controller while
    ///         minting shares to `receiver` — that mismatch is the bug.
    function handleOperation(
        address controller,
        address, /* receiver */
        uint256 assets,
        uint256 shares,
        Operation op
    ) external onlyVault {
        if (op == Operation.Deposit) {
            SuperVaultState storage state = superVaultState[controller];
            state.accumulatorShares += shares;
            state.accumulatorCostBasis += assets;
        }
    }

    /// @notice Strategist redeem-fulfilment entry: computes the cost basis for
    ///         the `controller`'s recorded state (reverts if it is empty).
    function handleRedeem(address controller, uint256 shares) external onlyVault returns (uint256 costBasis) {
        SuperVaultState storage state = superVaultState[controller];
        costBasis = _calculateCostBasis(state, shares);
    }

    // ── VERBATIM audited source: SuperVaultStrategy._calculateCostBasis ──────────
    function _calculateCostBasis(
        SuperVaultState storage state,
        uint256 requestedShares
    ) private returns (uint256 costBasis) {
        if (requestedShares > state.accumulatorShares) revert INSUFFICIENT_SHARES();
        // Calculate cost basis proportionally
        costBasis = requestedShares.mulDiv(state.accumulatorCostBasis, state.accumulatorShares, Math.Rounding.Floor);
        // Update user's accumulator state
        state.accumulatorShares -= requestedShares;
        state.accumulatorCostBasis -= costBasis;
        return costBasis;
    }
    // ────────────────────────────────────────────────────────────────────────────

    function getState(address controller) external view returns (uint256 accShares, uint256 accCostBasis) {
        SuperVaultState storage s = superVaultState[controller];
        return (s.accumulatorShares, s.accumulatorCostBasis);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault. Minimal ERC20 shares + custody of the asset. The deposit
// call-site is VERBATIM: state keyed to msg.sender (controller), shares to
// receiver. `redeem` models the ERC-7540 self-redeem: `owner` supplies the
// shares, `controller` supplies the cost-basis state.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVault {
    string public constant name = "SuperVault Shares";
    string public constant symbol = "svUSDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    MiniToken public immutable asset;
    ISuperVaultStrategy public immutable strategy;

    error NoSharesToRedeem();
    error NotOwner();

    constructor(MiniToken _asset, ISuperVaultStrategy _strategy) {
        asset = _asset;
        strategy = _strategy;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    /// @notice Deposit `assets`, minting shares to `receiver`. PPS is 1:1.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1 price-per-share

        // ── VERBATIM audited call-site: cost-basis state credited to the
        //    controller (msg.sender), shares minted to `receiver`. ──────────────
        strategy.handleOperation(msg.sender, receiver, assets, shares, ISuperVaultStrategy.Operation.Deposit); // @> state keyed to controller(msg.sender), not the share receiver
        _mint(receiver, shares);
    }

    /// @notice ERC-7540-style self redeem: `owner` supplies the shares, the
    ///         `controller`'s recorded cost-basis state is consumed on fulfilment.
    function redeem(uint256 shares, address controller, address owner) external returns (uint256 assets) {
        if (balanceOf[owner] < shares) revert NoSharesToRedeem();
        if (msg.sender != owner) revert NotOwner();
        // Strategist fulfilment: reverts INSUFFICIENT_SHARES if the controller's
        // recorded accumulator is empty.
        strategy.handleRedeem(controller, shares);
        _burn(owner, shares);
        assets = shares; // 1:1
        asset.transfer(owner, assets);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault (negative control). Applies the finding's recommendation: credit
// the strategy state to the `receiver`, not the controller. The strategy code is
// unchanged — only the deposit call-site's attribution is corrected.
// ─────────────────────────────────────────────────────────────────────────────
contract SuperVaultFixed {
    string public constant name = "SuperVault Shares";
    string public constant symbol = "svUSDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    MiniToken public immutable asset;
    ISuperVaultStrategy public immutable strategy;

    error NoSharesToRedeem();
    error NotOwner();

    constructor(MiniToken _asset, ISuperVaultStrategy _strategy) {
        asset = _asset;
        strategy = _strategy;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        // FIX: state credited to `receiver` (the share holder) — recommendation
        // `_handleDeposit(receiver, assets, shares)`.
        strategy.handleOperation(receiver, receiver, assets, shares, ISuperVaultStrategy.Operation.Deposit);
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address controller, address owner) external returns (uint256 assets) {
        if (balanceOf[owner] < shares) revert NoSharesToRedeem();
        if (msg.sender != owner) revert NotOwner();
        strategy.handleRedeem(controller, shares);
        _burn(owner, shares);
        assets = shares;
        asset.transfer(owner, assets);
    }
}

/// @dev Faithful minimal actor: the depositor (controller). It merely calls
///      `deposit`/`redeem` so that `msg.sender` (the controller) is a different
///      account from the receiver. It is NOT a mock of any vulnerable contract.
contract Depositor {
    function deposit(SuperVault vault, MiniToken usdc, uint256 assets, address receiver) external {
        usdc.approve(address(vault), assets);
        vault.deposit(assets, receiver);
    }

    function tryRedeem(SuperVault vault, uint256 shares) external {
        // controller == owner == this: this account holds the strategy state but
        // no shares, so `redeem` reverts NoSharesToRedeem.
        vault.redeem(shares, address(this), address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. A depositor deposits 100 USDC naming the Exploit contract as
// receiver (receiver != controller). The Exploit holds the shares, the depositor
// holds the state — and neither can redeem, so the 100 USDC is locked forever.
// The locked magnitude is recorded on the LOCKED-USDC marker at the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint256 internal constant DEPOSIT = 100_000_000; // 100 USDC (6 decimals)

    // Exposed results for the driver / Playground.
    address public vaultAddr;
    address public strategyAddr;
    address public markerAddr;
    address public depositorAddr;

    uint256 public receiverShares; // shares held by the receiver (Exploit)
    uint256 public receiverStateShares; // strategy accumulator for the receiver (0)
    uint256 public controllerStateShares; // strategy accumulator for the controller (100e6)
    uint256 public lockedAssets; // USDC stranded in the vault
    bool public receiverRedeemReverted; // receiver holds shares, empty state -> INSUFFICIENT_SHARES
    bool public controllerRedeemReverted; // controller holds state, no shares -> NoSharesToRedeem
    uint256 public sinkMarkerBalance;

    function run() external payable {
        // --- deploy the buggy set (fixed order; marker LAST) ---
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6); // nonce 1
        SuperVaultStrategy strategy = new SuperVaultStrategy(); // nonce 2
        SuperVault vault = new SuperVault(usdc, strategy); // nonce 3
        strategy.initialize(address(vault));
        Depositor depositor = new Depositor(); // nonce 4
        MiniToken marker = new MiniToken("Locked USDC", "LOCKED-USDC", 6); // nonce 5 (LAST)

        vaultAddr = address(vault);
        strategyAddr = address(strategy);
        markerAddr = address(marker);
        depositorAddr = address(depositor);

        // --- depositor deposits 100 USDC, naming the Exploit as receiver ---
        usdc.mint(address(depositor), DEPOSIT);
        depositor.deposit(vault, usdc, DEPOSIT, address(this)); // controller = depositor, receiver = this

        // Shares went to the receiver; the accumulator state to the controller.
        receiverShares = vault.balanceOf(address(this));
        (receiverStateShares,) = strategy.getState(address(this));
        (controllerStateShares,) = strategy.getState(address(depositor));

        // --- receiver (holds shares) tries to redeem: empty state -> revert ---
        try vault.redeem(receiverShares, address(this), address(this)) {
            receiverRedeemReverted = false;
        } catch {
            receiverRedeemReverted = true;
        }

        // --- controller (holds state) tries to redeem: no shares -> revert ---
        try depositor.tryRedeem(vault, DEPOSIT) {
            controllerRedeemReverted = false;
        } catch {
            controllerRedeemReverted = true;
        }

        // --- harm: neither party can redeem; the 100 USDC is locked in the vault ---
        require(receiverRedeemReverted, "receiver redeem unexpectedly succeeded");
        require(controllerRedeemReverted, "controller redeem unexpectedly succeeded");
        lockedAssets = usdc.balanceOf(address(vault));
        require(lockedAssets == DEPOSIT, "assets not locked");

        // Record the permanently-locked magnitude on the marker at the SINK.
        marker.mint(SINK, lockedAssets);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
