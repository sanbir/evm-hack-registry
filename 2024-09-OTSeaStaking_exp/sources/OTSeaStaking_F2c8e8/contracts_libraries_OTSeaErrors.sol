/*
        [....     [... [......  [.. ..
      [..    [..       [..    [..    [..
    [..        [..     [..     [..         [..       [..
    [..        [..     [..       [..     [.   [..  [..  [..
    [..        [..     [..          [.. [..... [..[..   [..
      [..     [..      [..    [..    [..[.        [..   [..
        [....          [..      [.. ..    [....     [.. [...

    https://otsea.io
    https://t.me/OTSeaPortal
    https://twitter.com/OTSeaERC20
*/

// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

/// @title Common OTSea errors
library OTSeaErrors {
    error InvalidAmount();
    error InvalidAddress();
    error InvalidIndex(uint256 index);
    error InvalidAmountAtIndex(uint256 index);
    error InvalidAddressAtIndex(uint256 index);
    error DuplicateAddressAtIndex(uint256 index);
    error AddressNotFoundAtIndex(uint256 index);
    error Unauthorized();
    error ExpectationMismatch();
    error InvalidArrayLength();
    error InvalidFee();
    error NotAvailable();
    error InvalidPurchase();
    error InvalidETH(uint256 expected);
    error Unchanged();
}
