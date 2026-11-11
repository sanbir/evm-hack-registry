// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sweep n' Flip — WERC721.royaltyInfo uses the wrong percentage unit
    (Cantina / slowfi, finding #46496, November 2024)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Bridge treats 0.001 ether as 1%. WERC721.royaltyInfo does
    salePrice * percentage / 1 ether, which treats 0.01 ether as 1%.
    A 1 ETH sale therefore pays 0.001 ETH (0.1%) instead of 0.01 ETH (1%).

    The royaltyInfo body is the function the report quotes. The console.log
    in the report is a debug print and is not part of the calculation.

    Report: https://cdn.cantina.xyz/reports/cantina_sweepnflip_bridge_november2024.pdf
*/

interface IERC2981 {
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address, uint256);
}

interface IRoyalty {
    function royaltyInfo(uint256 tokenId, uint256 salePrice) external view returns (address, uint256);
}

/// Collection that reports no royalty, so the bridge substitutes its 1% default.
contract UndefinedRoyalty is IERC2981 {
    function royaltyInfo(uint256, uint256) external pure returns (address, uint256) {
        return (address(0), 0);
    }
}

/// Bridge default: 0.001 ether means 1% when the collection does not report a royalty.
contract Bridge {
    function _getRoyaltyPercentage(address nftContract) public view returns (uint256) {
        try IERC2981(nftContract).royaltyInfo(0, 10000) returns (address, uint256 royaltyAmount) {
            return royaltyAmount > 0 ? royaltyAmount : 0.001 ether; // 1% if undefined
        } catch {
            return 0.001 ether; // 1% default
        }
    }
}

contract WERC721 is IRoyalty {
    struct RoyaltyData {
        address receiver;
        uint256 originalPercentage;
        uint256 wrapperPercentage;
    }

    RoyaltyData public s_royaltyInfo;

    function setRoyalty(address receiver, uint256 originalPercentage, uint256 wrapperPercentage) external {
        s_royaltyInfo = RoyaltyData(receiver, originalPercentage, wrapperPercentage);
    }

    function royaltyInfo(uint256 tokenId_, uint256 salePrice_) public view returns (address receiver, uint256 royaltyAmount) {
        tokenId_;
        uint256 percentage = s_royaltyInfo.originalPercentage + s_royaltyInfo.wrapperPercentage;
        // @> VULN: / 1 ether treats the bridge's 1% (0.001 ether) as 0.1%
        royaltyAmount = salePrice_ * percentage / 1 ether;
        // FIX: store 1% as 100 and return salePrice_ * percentage / 10_000
        receiver = s_royaltyInfo.receiver;
    }
}

/// Control: 1% is the constant 100, and the denominator matches that unit.
contract WERC721Fixed {
    address public receiver;

    constructor(address receiver_) {
        receiver = receiver_;
    }

    function royaltyInfo(uint256, uint256 salePrice_) public view returns (address, uint256 royaltyAmount) {
        uint256 percentage = 100; // 1%
        royaltyAmount = salePrice_ * percentage / 10_000;
        return (receiver, royaltyAmount);
    }
}

contract Sale {
    function buy(IRoyalty nft, uint256 tokenId, address payable seller) external payable returns (uint256 paid) {
        (address receiver, uint256 royaltyAmount) = nft.royaltyInfo(tokenId, msg.value);
        paid = royaltyAmount;
        (bool ok,) = payable(receiver).call{value: royaltyAmount}("");
        require(ok, "royalty transfer");
        (bool okSeller,) = seller.call{value: msg.value - royaltyAmount}("");
        require(okSeller, "seller transfer");
    }
}

contract Exploit {
    uint256 public constant SALE_PRICE = 1 ether;
    uint256 public constant PAID_WRONG = 0.001 ether;
    uint256 public constant FAIR = 0.01 ether;
    address public constant RECEIVER = 0x2222222222222222222222222222222222222222;
    address public constant SELLER = 0x3333333333333333333333333333333333333333;

    Bridge public bridge;
    UndefinedRoyalty public undefinedRoyalty;
    WERC721 public nft;
    Sale public sale;
    uint256 public paidRoyalty;
    uint256 public fairRoyalty;

    function run() external payable {
        bridge = new Bridge();
        undefinedRoyalty = new UndefinedRoyalty();
        nft = new WERC721();
        sale = new Sale();

        uint256 onePercent = bridge._getRoyaltyPercentage(address(undefinedRoyalty));
        require(onePercent == 0.001 ether, "bridge 1% unit");
        nft.setRoyalty(RECEIVER, onePercent, 0);

        require(msg.value == SALE_PRICE, "sale is 1 ETH");
        paidRoyalty = sale.buy{value: msg.value}(nft, 1, payable(SELLER));
        fairRoyalty = SALE_PRICE / 100;

        require(paidRoyalty == PAID_WRONG, "sale paid the wrong royalty");
        require(fairRoyalty == FAIR, "fair royalty is 1 percent");
        require(paidRoyalty != fairRoyalty, "paid matched the fair royalty");
        require(RECEIVER.balance == PAID_WRONG, "receiver got the wrong amount");
        require(SELLER.balance == SALE_PRICE - PAID_WRONG, "seller kept the unpaid royalty");
    }
}
