// Copyright (C) 2020-2024 SubQuery Pte Ltd authors & contributors
// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.15;

import '../interfaces/ISettings.sol';

abstract contract SQParameter {
    /// @notice Emitted when parameter change.
    event Parameter(string name, bytes value);

    function _requireNotBlacklisted(ISettings settings, address wallet) internal view {
        if (settings.isWalletBlacklisted(wallet)) {
            revert();
        }
    }
}
