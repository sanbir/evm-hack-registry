// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title NFTUtils
 * @dev Library providing utility functions for NFT metadata handling
 */
library NFTUtils {
    bytes16 private constant HEX_DIGITS = "0123456789abcdef";

    /**
     * @notice Converts an unsigned integer into its decimal string representation, with optional thousand separators and fixed‐point decimals.
     * @dev
     *  - Iterates through each digit (least significant first), inserts a decimal point after `decimals` digits,
     *    and inserts commas every three digits to the left of the decimal if `thousandSeparator` is true.
     *  - If the number of digits is less than `decimals`, it pads with leading zeros to ensure exactly `decimals` fractional places.
     *  - Uses an internal lookup table `HEX_DIGITS` for digit-to-character mapping.
     *
     * @param _number            The integer value to format.
     * @param _thousandSeparator If true, inserts commas as thousand separators (e.g., "1,234,567").
     * @param _decimals          The number of digits to treat as the fractional part (e.g., 2 for two decimal places).
     * @return string            Formatted number, including decimal point and commas as specified.
     */
    function uintToString(
        uint256 _number,
        bool _thousandSeparator,
        uint256 _decimals
    ) internal pure returns (string memory) {
        if (_number == 0) {
            return "0";
        }

        bytes memory buf = new bytes(0);
        uint256 pow = 0;

        for (; _number != 0; pow++) {
            uint256 digit = _number % 10;
            if (_decimals > 0 && pow == _decimals) buf = bytes.concat(".", buf);
            if (
                _thousandSeparator &&
                pow > _decimals &&
                (pow - _decimals) % 3 == 0
            ) buf = bytes.concat(",", buf);
            buf = bytes.concat(HEX_DIGITS[digit], buf);
            _number /= 10;
        }

        if (_decimals >= pow) {
            bytes memory repeat = new bytes(_decimals - pow);
            for (uint256 i = 0; i < repeat.length; i++) {
                repeat[i] = "0";
            }

            buf = bytes.concat("0.", repeat, buf);
        }

        return string(buf);
    }

    /**
     * @notice Converts an address to its string representation
     * @dev Converts the address to a hexadecimal string, including the "0x" prefix
     * @param _addr The address to convert
     * @return string The address as a hexadecimal string
     */
    function addressToString(
        address _addr
    ) internal pure returns (string memory) {
        uint256 localValue = uint256(uint160(_addr));
        bytes memory buffer = new bytes(42);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 41; i > 1; --i) {
            buffer[i] = HEX_DIGITS[localValue & 0xf];
            localValue >>= 4;
        }
        return string(buffer);
    }

    /**
     * @notice Shortens a hexadecimal address or any long string by keeping the first 8 and last 8 characters.
     * @param _longString The string to shorten
     * @return string A shortened version of the string with ellipsis in the middle.
     */
    function shortenString(string memory _longString) public pure returns (string memory) {
        bytes memory strBytes = bytes(_longString);

        if (strBytes.length > 16) {
            // Allocate space for first 8 characters
            bytes memory first = new bytes(8);
            for (uint i = 0; i < 8; i++) {
                first[i] = strBytes[i];
            }

            // Allocate space for last 8 characters
            bytes memory last = new bytes(8);
            for (uint i = 0; i < 8; i++) {
                last[i] = strBytes[strBytes.length - 8 + i];
            }

            // Return the combined shortened address string
            return string(abi.encodePacked(string(first), "...", string(last))); 
        }
        else {
            // If less than or equal to 16 characters, return as is
            return _longString;
        }
    }

    /**
    * @notice Converts a Unix timestamp (seconds since 1970-01-01) to a human-readable date string in “DD/MM/YYYY” format.
    * @dev
    *  - Uses the “civil from days” algorithm to handle Gregorian calendar rules, including leap years.
    *  - Converts the timestamp to a day count, computes the era, year, month, and day components.
    *  - Returns a concatenated string of the form “D/M/YYYY” (no leading zeros on day/month).
    *
    * @param _timestamp The Unix timestamp to convert.
    * @return string A `string` representing the date in “DD/MM/YYYY” format.
    */
    function timestampToDate(
        uint256 _timestamp
    ) public pure returns (string memory) {
        uint256 z = _timestamp / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z % 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 d = doy - (153 * mp + 2) / 5 + 1;
        uint256 m = mp + (mp < 10 ? 12 : 0) - 9;
        y+= (m <= 2 ? 1 : 0);
        return string.concat(uintToString(d, false, 0), "/", uintToString(m, false, 0), "/", uintToString(y, false, 0));
    }
}