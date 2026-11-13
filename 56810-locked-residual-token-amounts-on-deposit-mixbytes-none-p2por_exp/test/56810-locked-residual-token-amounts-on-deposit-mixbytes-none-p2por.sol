// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  P2P Yield Proxy _deposit (MixBytes, AuditVault #56810).
    SYNTHETIC, cheatcode-free, single transaction.

    The ERC-20 branch pulls `amount` and forwards only
    amount * s_clientBasisPointsOfDeposit / 10_000. The residual stays in
    the proxy. Deposits and withdrawals account only the forwarded value,
    so the residual has no withdrawal path. */

contract Mini {
    string public constant name = "Yield Asset";
    string public constant symbol = "YLD";
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

contract Underlying {
    Mini public immutable token;

    constructor(Mini token_) {
        token = token_;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external {
        token.transfer(msg.sender, amount);
    }
}

contract P2pYieldProxy {
    Mini public immutable token;
    Underlying public immutable underlying;
    uint256 public s_clientBasisPointsOfDeposit;
    mapping(address => uint256) public deposits;

    constructor(Mini token_, Underlying underlying_, uint256 bps) {
        token = token_;
        underlying = underlying_;
        s_clientBasisPointsOfDeposit = bps;
    }

    function _deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 amountToDepositAfterFee = amount * s_clientBasisPointsOfDeposit / 10_000;
        token.approve(address(underlying), amountToDepositAfterFee);
        // @> VULN: amount - amountToDepositAfterFee stays in this proxy with no withdrawal path
        underlying.deposit(amountToDepositAfterFee);
        deposits[msg.sender] += amountToDepositAfterFee;
    }

    function withdrawAll() external returns (uint256 out) {
        out = deposits[msg.sender];
        deposits[msg.sender] = 0;
        underlying.withdraw(out);
        token.transfer(msg.sender, out);
    }
}

contract P2pYieldProxyFixed {
    Mini public immutable token;
    Underlying public immutable underlying;
    address public immutable treasury;
    uint256 public s_clientBasisPointsOfDeposit;
    mapping(address => uint256) public deposits;

    constructor(Mini token_, Underlying underlying_, address treasury_, uint256 bps) {
        token = token_;
        underlying = underlying_;
        treasury = treasury_;
        s_clientBasisPointsOfDeposit = bps;
    }

    function _deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        uint256 amountToDepositAfterFee = amount * s_clientBasisPointsOfDeposit / 10_000;
        uint256 residual = amount - amountToDepositAfterFee;
        if (residual > 0) token.transfer(treasury, residual);
        token.approve(address(underlying), amountToDepositAfterFee);
        underlying.deposit(amountToDepositAfterFee);
        deposits[msg.sender] += amountToDepositAfterFee;
    }

    function withdrawAll() external returns (uint256 out) {
        out = deposits[msg.sender];
        deposits[msg.sender] = 0;
        underlying.withdraw(out);
        token.transfer(msg.sender, out);
    }
}

contract Exploit {
    uint256 internal constant DEPOSIT = 10_000 ether;
    uint256 internal constant BPS = 8_000;

    Mini public token;
    Underlying public underlying;
    P2pYieldProxy public proxy;
    uint256 public forwarded;
    uint256 public residualBeforeWithdraw;
    uint256 public accounted;
    uint256 public userGot;
    uint256 public residualLocked;
    uint256 public proxyAfterWithdraw;

    function run() external {
        token = new Mini();
        underlying = new Underlying(token);
        proxy = new P2pYieldProxy(token, underlying, BPS);
        token.mint(address(this), DEPOSIT);
        token.approve(address(proxy), DEPOSIT);
        forwarded = DEPOSIT * BPS / 10_000;
        proxy._deposit(DEPOSIT);
        residualBeforeWithdraw = token.balanceOf(address(proxy));
        accounted = proxy.deposits(address(this));
        userGot = proxy.withdrawAll();
        residualLocked = token.balanceOf(address(proxy));
        proxyAfterWithdraw = residualLocked;
    }
}
