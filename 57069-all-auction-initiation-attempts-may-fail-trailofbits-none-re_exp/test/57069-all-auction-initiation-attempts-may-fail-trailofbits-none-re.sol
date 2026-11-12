// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Reserve GnosisTrade — initiateAuction pulls sellAmount plus the fee
    (Trail of Bits, August 2022).
    SYNTHETIC, cheatcode-free. No time warp.
    The trade approves sellAmount (10100). EasyAuction's fee is 1 percent,
    so it pulls 10100 * 101 / 100 = 10201. transferFrom reverts.
    The 10100 collateral stays in the trade and the auction id stays 0.
    Approving the budget and auctioning sellAmount / 1.01 starts the
    auction, and a bidder pays 5000. */

contract Token {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract EasyAuction {
    uint256 public constant FEE_DENOMINATOR = 100;
    uint256 public feeNumerator = 1;
    uint256 public auctionId;
    uint256 public bids;

    function initiateAuction(Token _auctioningToken, uint256 _auctionedSellAmount) external returns (uint256) {
        uint256 pull = _auctionedSellAmount * (FEE_DENOMINATOR + feeNumerator) / FEE_DENOMINATOR;
        // @> VULN: pulls sellAmount plus the fee. The trade only approved sellAmount, so the auction reverts.
        pulled = pull;
        _auctioningToken.transferFrom(msg.sender, address(this), pull);
        auctionId += 1;
        return auctionId;
    }

    uint256 public pulled;

    function bid(Token buy, uint256 amount) external {
        require(auctionId != 0, "no auction");
        buy.transferFrom(msg.sender, address(this), amount);
        bids += amount;
    }
}

contract GnosisTrade {
    Token public sell;
    EasyAuction public gnosis;
    uint256 public auctionId;
    bool public started;

    constructor(Token sell_, EasyAuction gnosis_) {
        sell = sell_;
        gnosis = gnosis_;
    }

    function init(uint256 sellAmount) external {
        sell.approve(address(gnosis), sellAmount);
        try gnosis.initiateAuction(sell, sellAmount) returns (uint256 id) {
            auctionId = id;
            started = true;
        } catch {
            auctionId = 0;
            started = false;
        }
    }
}

contract Exploit {
    Token public sell; // nonce 1
    Token public buy; // nonce 2
    EasyAuction public auction; // nonce 3
    GnosisTrade public trade; // nonce 4

    constructor() {
        sell = new Token();
        buy = new Token();
        auction = new EasyAuction();
        trade = new GnosisTrade(sell, auction);
    }

    function run() external {
        sell.mint(address(trade), 10100);
        trade.init(10100);
        require(trade.started() == false, "auction started");
        require(trade.auctionId() == 0, "auction id");
        require(sell.balanceOf(address(trade)) == 10100, "10100 was sold");
        require(sell.balanceOf(address(auction)) == 0, "auction received collateral");
        require(auction.bids() == 0, "a bidder paid");
    }
}
