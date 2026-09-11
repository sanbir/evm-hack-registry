// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.19;

type BtcSerial is uint64;

using {inc, equal as ==} for BtcSerial global;

function inc(BtcSerial a) pure returns (BtcSerial) {
    return BtcSerial.wrap(BtcSerial.unwrap(a) + 1);
}

function equal(BtcSerial a, BtcSerial b) pure returns (bool) {
    return BtcSerial.unwrap(a) == BtcSerial.unwrap(b);
}
