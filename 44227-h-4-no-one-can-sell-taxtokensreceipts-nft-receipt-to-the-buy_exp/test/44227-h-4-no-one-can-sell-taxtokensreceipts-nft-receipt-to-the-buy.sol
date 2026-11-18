// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Debita TaxTokensReceipt — buy orders are not an allowed transfer counterparty
   (Sherlock H-4, AuditVault 44227). SYNTHETIC, cheatcode-free.
   transferFrom reverts unless from or to is a borrow order, a lend order, or a loan.
   sellNFT always hits that require, so Bob's 1000 USDC cannot buy Alice's receipt. */

contract Cash {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Registry {
    mapping(address => bool) public borrowOrder;
    mapping(address => bool) public lendOrder;
    mapping(address => bool) public loan;

    function markBorrow(address a) external {
        borrowOrder[a] = true;
    }

    function markLend(address a) external {
        lendOrder[a] = true;
    }

    function markLoan(address a) external {
        loan[a] = true;
    }

    function isBorrowOrderLegit(address a) external view returns (bool) {
        return borrowOrder[a];
    }

    function isLendOrderLegit(address a) external view returns (bool) {
        return lendOrder[a];
    }

    function isSenderALoan(address a) external view returns (bool) {
        return loan[a];
    }
}

contract TaxTokensReceipt {
    Registry public registry;
    mapping(uint256 => address) public ownerOf;

    constructor(Registry _registry) {
        registry = _registry;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        bool isReceiverAddressDebita = registry.isBorrowOrderLegit(to) || registry.isLendOrderLegit(to)
            || registry.isSenderALoan(to);
        bool isSenderAddressDebita = registry.isBorrowOrderLegit(from) || registry.isLendOrderLegit(from)
            || registry.isSenderALoan(from);
        require(
            isReceiverAddressDebita || isSenderAddressDebita,
            "TaxTokensReceipts: Debita not involved"
        ); // @> VULN: a buy order is neither borrower, lender, nor loan, so every sellNFT transfer reverts
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
    }
}

contract BuyOrder {
    struct BuyInformation {
        bool isActive;
        uint256 availableAmount;
        address wantedToken;
    }

    BuyInformation public buyInformation;
    Cash public cash;
    address public constant SELLER = address(uint160(0xA11CE));

    constructor(Cash _cash, address receipt) {
        cash = _cash;
        buyInformation = BuyInformation({isActive: true, availableAmount: 1000 ether, wantedToken: receipt});
    }

    function sellNFT(uint256 receiptID) public {
        require(buyInformation.isActive, "Buy order is not active");
        require(buyInformation.availableAmount > 0, "Buy order is not available");

        TaxTokensReceipt(buyInformation.wantedToken).transferFrom(msg.sender, address(this), receiptID);

        uint256 pay = buyInformation.availableAmount;
        buyInformation.availableAmount = 0;
        cash.transfer(msg.sender, pay);
    }
}

contract Seller {
    function sell(BuyOrder order, uint256 id) external {
        order.sellNFT(id);
    }
}

contract Exploit {
    Cash public cash; // nonce 1
    Registry public registry; // nonce 2
    TaxTokensReceipt public receipt; // nonce 3
    BuyOrder public buyOrder; // nonce 4
    Seller public alice; // nonce 5
    bool public saleReverted;
    uint256 public aliceCash;
    uint256 public orderCash;
    address public nftOwner;

    constructor() {
        cash = new Cash();
        registry = new Registry();
        receipt = new TaxTokensReceipt(registry);
        buyOrder = new BuyOrder(cash, address(receipt));
        alice = new Seller();
    }

    function run() external {
        receipt.mint(address(alice), 1);
        cash.mint(address(buyOrder), 1000 ether);
        registry.markBorrow(address(0xB0B));
        registry.markLend(address(0xB0C));
        registry.markLoan(address(0xB0D));

        try alice.sell(buyOrder, 1) {
            saleReverted = false;
        } catch {
            saleReverted = true;
        }

        aliceCash = cash.balanceOf(address(alice));
        orderCash = cash.balanceOf(address(buyOrder));
        nftOwner = receipt.ownerOf(1);
        require(saleReverted, "sale succeeded");
        require(aliceCash == 0, "seller was paid");
        require(orderCash == 1000 ether, "escrow moved");
        require(nftOwner == address(alice), "receipt moved");
    }
}
