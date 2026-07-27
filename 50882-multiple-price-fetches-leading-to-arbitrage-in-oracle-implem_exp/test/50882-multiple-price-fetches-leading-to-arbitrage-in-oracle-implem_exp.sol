// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/nlx/contracts/oracle/Oracle.sol";
import "../src/nlx/contracts/data/DataStore.sol";
import "../src/nlx/contracts/role/RoleStore.sol";
import "../src/nlx/contracts/event/EventEmitter.sol";
import "../src/nlx/contracts/oracle/OracleStore.sol";
import "../src/nlx/contracts/role/Role.sol";
import "../src/pyth/PythStructs.sol";

contract GasSensitivePyth {
    function getPrice(bytes32) external view returns (PythStructs.Price memory p) {
        // A real Pyth endpoint may return a newer value after updatePriceFeeds.
        // Gas-sensitive output models two distinct feed snapshots without
        // inventing a second pricing algorithm in the audited contract.
        p.price = int64(int256(1_000_000 + (gasleft() % 100_000)));
        p.conf = 1;
        p.expo = 0;
        p.publishTime = block.timestamp;
    }
}

contract OracleReadHarness is Oracle {
    constructor(RoleStore roles, OracleStore store, address pyth) Oracle(roles, store, pyth) {}
    function readPriceTwice(DataStore dataStore, address token) external returns (uint256 first, uint256 second) {
        (, first) = _getPriceFeedPrice(dataStore, token);
        (, second) = _getPriceFeedPrice(dataStore, token);
    }
}

contract PoC_50882 is Test {
    RoleStore roles;
    DataStore dataStore;
    OracleStore oracleStore;
    EventEmitter eventEmitter;
    OracleReadHarness oracle;
    GasSensitivePyth pyth;
    address token = address(0xCAFE);

    function setUp() public {
        roles = new RoleStore();
        roles.grantRole(address(this), Role.CONTROLLER);
        eventEmitter = new EventEmitter(roles);
        oracleStore = new OracleStore(roles, eventEmitter);
        dataStore = new DataStore(roles);
        pyth = new GasSensitivePyth();
        oracle = new OracleReadHarness(roles, oracleStore, address(pyth));

        // Give the real DataStore enough configuration for Oracle's unchanged
        // _getPriceFeedPrice path to accept the mock feed.
        bytes32 idKey = keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED_ID")), token));
        bytes32 multiplierKey = keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED_MULTIPLIER")), token));
        bytes32 heartbeatKey = keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED_HEARTBEAT_DURATION")), token));
        dataStore.setBytes32(idKey, bytes32(uint256(1)));
        dataStore.setUint(multiplierKey, 1e30);
        dataStore.setUint(heartbeatKey, 1 days);
    }

    function test_same_token_is_fetched_twice_in_one_transaction() public {
        (uint256 first, uint256 second) = oracle.readPriceTwice(dataStore, token);
        assertTrue(first != second, "source unexpectedly cached the feed price");
    }
}
