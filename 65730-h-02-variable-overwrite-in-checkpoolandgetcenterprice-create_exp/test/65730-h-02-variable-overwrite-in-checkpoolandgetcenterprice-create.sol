// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Olas checkPoolAndGetCenterPrice (Code4rena, 2026-01).
    The return variable is first the spot, then it is overwritten
    with the TWAP. The deviation compares that value with itself
    and is 0. Spot 100 against TWAP 200 is a gap of 100. The
    control keeps the spot and reports 100.
*/

contract Checker {
    uint256 public spotStored;
    uint256 public overwritten;
    uint256 public instantStored;
    uint256 public twapStored;
    uint256 public lastDeviation;
    bool public accepted;
    uint256 public counted;

    function check(uint256 spot, uint256 twap) public returns (uint256 deviation) {
        uint256 center = spot;
        spotStored = center;
        center = twap;
        overwritten = center;
        uint256 instant = center;
        instantStored = instant;
        twapStored = twap;
        deviation = instant > twap ? instant - twap : twap - instant; // @> VULN: instant was derived from the overwritten center, so this is |twap - twap|
        lastDeviation = deviation;
        accepted = deviation <= 10;
        counted += 1;
    }
}

contract CheckerFixed {
    function check(uint256 spot, uint256 twap) public pure returns (uint256 deviation) {
        deviation = spot > twap ? spot - twap : twap - spot;
    }
}

contract MissMarker {
    string public symbol = "MISSED-GAP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Checker public checker;
    MissMarker public marker;

    function run() external {
        checker = new Checker();
        marker = new MissMarker();
        uint256 gap = checker.check(100 ether, 200 ether);
        require(gap == 0, "deviation is 0");
        require(checker.accepted(), "100 percent gap is accepted");
        marker.mint(SINK, 100 ether);
        require(marker.balanceOf(SINK) == 100 ether, "gap of 100");
    }
}
