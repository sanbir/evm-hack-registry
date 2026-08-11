// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of YuzuUSD finding 62756:
// "[H-01] Pending withdrawals in `YuzuILP` are not considered in totalAssets".
//
// YuzuILP / YuzuOrderBook is an async-redeem ERC4626-style vault. When a user
// creates a redeem order, `createRedeemOrder` computes and *fixes* the asset
// amount they will receive at the CURRENT (pre-yield) vault price via
// `previewRedeemOrder(tokens)`. The bug is an OMISSION: the tokens being
// redeemed are NOT excluded from `totalAssets()` / `totalSupply()` while the
// order is pending, so those shares keep accruing yield inside the vault. At
// finalize the withdrawer is paid only the fixed pre-yield amount, and the
// yield their still-participating shares earned during the pending window is
// left behind and redistributed to the remaining holders. The withdrawer loses
// their rightful share of the pending-window yield.
//
// Only `createRedeemOrder` is embedded VERBATIM from the Pashov write-up (the
// bug is an omission in the surrounding accounting described in prose), so the
// vault is reconstructed as a faithful minimal ERC4626 async-redeem model. The
// verbatim buggy function is inlined byte-for-byte and marked with `// @>`.
//
// Scenario (numbers): depositor A and B each deposit 100. A createRedeemOrder
// for all 100 shares -> value fixed at 100 (pre-yield). 100 of yield then
// accrues (rebase). A finalizes and receives only 100. A's still-participating
// 100 shares (50% of supply) rightfully earned 50 of that yield, so A's fair
// pro-rata is 150 -> A loses 50, which leaks to B (B's redeemable rises from a
// fair 150 to 200). The 50 LOST-YIELD is recorded on a marker token to the SINK.
//
// Negative control (`YuzuOrderBookFixed`): the withdrawer's still-participating
// shares are honored at the finalize-time price -> A gets the full pro-rata 150,
// no yield leaks. This isolates the harm to the buggy fixed-at-creation payout.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double for the vault's underlying asset and the marker.
///      `mint` doubles as the "rebase" primitive (transfer asset into the vault).
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

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault. `createRedeemOrder` is inlined VERBATIM from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract YuzuOrderBook {
    error InvalidZeroAddress();
    error ExceededMaxRedeemOrder(address owner, uint256 tokens, uint256 maxTokens);

    event CreatedRedeemOrder(
        address caller, address receiver, address owner, uint256 orderId, uint256 assets, uint256 tokens
    );

    MiniToken public asset;
    uint256 public totalSupply; // total shares == ERC4626 totalSupply()
    mapping(address => uint256) public balanceOf; // share balances

    struct RedeemOrder {
        address receiver;
        address owner;
        uint256 tokens; // escrowed shares (still counted in totalSupply -- the bug)
        uint256 assets; // asset amount FIXED at creation (pre-yield price)
        bool finalized;
    }

    RedeemOrder[] public orders;

    constructor(address _asset) {
        asset = MiniToken(_asset);
    }

    // --- ERC4626-style accounting -------------------------------------------
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    function convertToShares(uint256 assets_) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets_ : assets_ * supply / totalAssets();
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares_ : shares_ * totalAssets() / supply;
    }

    function previewDeposit(uint256 assets_) public view returns (uint256) {
        return convertToShares(assets_);
    }

    function previewRedeemOrder(uint256 tokens) public view returns (uint256) {
        return convertToAssets(tokens);
    }

    function maxRedeemOrder(address owner) public view returns (uint256) {
        return balanceOf[owner];
    }

    /// @notice Deposit `assets_`, mint shares to `receiver`. Shares priced off
    ///         totalAssets() BEFORE the incoming transfer (standard ERC4626).
    function deposit(uint256 assets_, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(assets_);
        asset.transferFrom(msg.sender, address(this), assets_);
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    // ── VERBATIM from the Pashov write-up (YuzuOrderBook.createRedeemOrder) ──
    function createRedeemOrder(uint256 tokens, address receiver, address owner)
        public
        virtual
        returns (uint256, uint256)
    {
        if (receiver == address(0)) {
            revert InvalidZeroAddress();
        }
        uint256 maxTokens = maxRedeemOrder(owner);
        if (tokens > maxTokens) {
            revert ExceededMaxRedeemOrder(owner, tokens, maxTokens);
        }

        uint256 assets = previewRedeemOrder(tokens); // @> asset value FIXED at current pre-yield price; the redeemed shares are NOT excluded from totalAssets()/totalSupply(), so they keep accruing yield the withdrawer never receives
        address caller = _msgSender();
        uint256 orderId = _createRedeemOrder(caller, receiver, owner, tokens, assets);

        emit CreatedRedeemOrder(caller, receiver, owner, orderId, assets, tokens);

        return (orderId, assets);
    }
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Escrows the redeemed shares into the vault. They remain part of
    ///         totalSupply (and their assets part of totalAssets) while pending
    ///         -- this is precisely the accounting the finding says must be
    ///         excluded. Records the pre-yield `assets_` for payout at finalize.
    function _createRedeemOrder(address, /*caller*/ address receiver, address owner, uint256 tokens, uint256 assets_)
        internal
        returns (uint256)
    {
        balanceOf[owner] -= tokens;
        balanceOf[address(this)] += tokens; // escrow; totalSupply unchanged (bug)
        orders.push(RedeemOrder({receiver: receiver, owner: owner, tokens: tokens, assets: assets_, finalized: false}));
        return orders.length - 1;
    }

    /// @notice Finalize: pay the withdrawer the amount recorded at creation.
    function finalizeRedeem(uint256 orderId) external virtual returns (uint256) {
        RedeemOrder storage o = orders[orderId];
        require(!o.finalized, "finalized");
        o.finalized = true;

        uint256 payout = o.assets; // consequence: pays the stale, fixed pre-yield amount, ignoring the yield the escrowed shares accrued while pending

        balanceOf[address(this)] -= o.tokens;
        totalSupply -= o.tokens; // burn escrowed shares only now
        asset.transfer(o.receiver, payout);
        return payout;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault (negative control). Identical vault mechanics and the identical
// verbatim `createRedeemOrder`; the ONLY change is that finalize honors the
// still-participating shares at the current price, so the withdrawer receives
// their full pro-rata (principal + pending-window yield) and no yield leaks.
// ─────────────────────────────────────────────────────────────────────────────
contract YuzuOrderBookFixed is YuzuOrderBook {
    constructor(address _asset) YuzuOrderBook(_asset) {}

    function finalizeRedeem(uint256 orderId) external override returns (uint256) {
        RedeemOrder storage o = orders[orderId];
        require(!o.finalized, "finalized");
        o.finalized = true;

        // FIX: value the escrowed shares at the CURRENT price at finalize, so
        // the yield they earned while pending is paid to the withdrawer.
        uint256 payout = convertToAssets(o.tokens);

        balanceOf[address(this)] -= o.tokens;
        totalSupply -= o.tokens;
        asset.transfer(o.receiver, payout);
        return payout;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: A and B each deposit 100. A opens a redeem order (value fixed
// at 100). 100 of yield accrues. A finalizes and gets only 100, while A's
// still-participating shares rightfully earned 50 (fair pro-rata = 150). The 50
// LOST-YIELD leaks to B and is recorded on a marker token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant WITHDRAWER = 0x000000000000000000000000000000000000aaaa; // depositor A (redeems)
    address internal constant REMAINING = 0x000000000000000000000000000000000000BbBB; // depositor B (stays)

    uint256 internal constant DEPOSIT = 100 ether;
    uint256 internal constant REDEEM_TOKENS = 100 ether;
    uint256 internal constant YIELD = 100 ether;

    // Exposed results for the driver.
    uint256 public withdrawerPayout; // A's actual payout under the bug (fixed pre-yield amount)
    uint256 public withdrawerFair; // A's fair pro-rata at finalize (principal + pending-window yield)
    uint256 public remainingRedeemableBuggy; // B's redeemable after the bug (windfall)
    uint256 public lostYield; // A's shortfall == yield leaked to B
    uint256 public sinkMarkerBalance; // marker recording the LOST-YIELD at SINK
    address public vaultAddr;
    address public assetAddr;
    address public markerAddr;

    function run() external payable {
        // --- deploy asset, vault, marker (fixed order; marker LAST) ---
        MiniToken assetToken = new MiniToken("Yuzu USD", "yUSD"); // nonce 1
        YuzuOrderBook vault = new YuzuOrderBook(address(assetToken)); // nonce 2
        MiniToken marker = new MiniToken("Lost Yield", "LOST-YIELD"); // nonce 3 (LAST)

        assetAddr = address(assetToken);
        vaultAddr = address(vault);
        markerAddr = address(marker);

        // --- fund this contract and let it deposit on behalf of A and B ---
        assetToken.mint(address(this), DEPOSIT * 2);
        assetToken.approve(address(vault), type(uint256).max);

        vault.deposit(DEPOSIT, WITHDRAWER); // A: 100 shares
        vault.deposit(DEPOSIT, REMAINING); // B: 100 shares
        // vault now holds 200 assets, totalSupply == 200 (A:100, B:100)

        // --- A opens a redeem order for all 100 shares (value fixed at 100) ---
        (uint256 orderId, uint256 fixedAssets) = vault.createRedeemOrder(REDEEM_TOKENS, WITHDRAWER, WITHDRAWER);
        require(fixedAssets == 100 ether, "unexpected fixed valuation");

        // --- yield accrues into the vault (rebase): +100 assets ---
        assetToken.mint(address(vault), YIELD); // vault holds 300 assets, totalSupply still 200

        // --- A's still-participating shares are now worth their fair pro-rata ---
        withdrawerFair = vault.convertToAssets(REDEEM_TOKENS); // 100 * 300 / 200 = 150

        // --- A finalizes: receives only the fixed pre-yield amount ---
        withdrawerPayout = vault.finalizeRedeem(orderId); // 100

        // --- B's redeemable value has risen above its fair share (windfall) ---
        remainingRedeemableBuggy = vault.convertToAssets(vault.balanceOf(REMAINING)); // 100 * 200 / 100 = 200

        // --- HARM: the withdrawer's pending-window yield is lost and leaks to B ---
        lostYield = withdrawerFair - withdrawerPayout; // 150 - 100 = 50
        marker.mint(SINK, lostYield);
        sinkMarkerBalance = marker.balanceOf(SINK);

        require(withdrawerPayout < withdrawerFair, "no shortfall -> no harm");
        require(lostYield > 0, "no lost yield");
        require(remainingRedeemableBuggy > withdrawerFair, "yield did not leak to remaining holder");
        require(sinkMarkerBalance == lostYield, "marker mismatch");
    }
}
