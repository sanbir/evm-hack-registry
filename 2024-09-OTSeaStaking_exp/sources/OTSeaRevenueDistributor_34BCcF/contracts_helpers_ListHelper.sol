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

import "contracts/libraries/OTSeaErrors.sol";

/// @title A list helper contract
abstract contract ListHelper {
    uint16 internal constant LOOP_LIMIT = 500;
    bool internal constant ALLOW_ZERO = true;
    bool internal constant DISALLOW_ZERO = false;

    error InvalidStart();
    error InvalidEnd();
    error InvalidSequence();

    /**
     * @param _start Start
     * @param _end End
     * @param _total List total
     * @param _allowZero true - zero is a valid start or end, false - zero is an invalid start or end
     */
    modifier onlyValidSequence(
        uint256 _start,
        uint256 _end,
        uint256 _total,
        bool _allowZero
    ) {
        _checkSequence(_start, _end, _total, _allowZero);
        _;
    }

    /**
     * @param _start Start
     * @param _end End
     * @param _total Total
     * @param _allowZero true - zero is a valid start or end, false - zero is an invalid start or end
     * @dev check that a range of indexes is valid.
     */
    function _checkSequence(
        uint256 _start,
        uint256 _end,
        uint256 _total,
        bool _allowZero
    ) private pure {
        if (_allowZero) {
            if (_start >= _total) revert InvalidStart();
            if (_end >= _total) revert InvalidEnd();
        } else {
            if (_start == 0 || _start > _total) revert InvalidStart();
            if (_end == 0 || _end > _total) revert InvalidEnd();
        }
        if (_start > _end) revert InvalidStart();
        if (_end - _start + 1 > LOOP_LIMIT) revert InvalidSequence();
    }

    /// @dev _length List length
    function _validateListLength(uint256 _length) internal pure {
        if (_length == 0 || LOOP_LIMIT < _length) revert OTSeaErrors.InvalidArrayLength();
    }
}
