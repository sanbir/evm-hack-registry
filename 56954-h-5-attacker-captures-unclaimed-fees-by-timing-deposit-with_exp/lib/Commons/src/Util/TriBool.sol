// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2023 Itos Inc.
pragma solidity ^0.8.17;

enum TriBool {
    False,
    True,
    None
}

library TriBoolImpl {
    error UndecidableTriBool();

    function asBool(TriBool self) internal pure returns (bool) {
        if (self == TriBool.True) {
            return true;
        } else if (self == TriBool.False) {
            return false;
        } else {
            revert UndecidableTriBool();
        }
    }

    function asUint(TriBool self) internal pure returns (uint8) {
        return uint8(self);
    }

    function isTrue(TriBool self) internal pure returns (bool) {
        return self == TriBool.True;
    }

    function isFalse(TriBool self) internal pure returns (bool) {
        return self == TriBool.False;
    }
}