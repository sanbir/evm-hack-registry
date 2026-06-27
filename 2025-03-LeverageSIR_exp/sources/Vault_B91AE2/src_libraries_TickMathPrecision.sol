// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./FullMath.sol";
import {SystemConstants} from "./SystemConstants.sol";

/// @notice Modified from Uniswap v3 TickMath
/// @notice Math library for computing log_1.0001(x/y) and 1.0001^z where x and y are uint and z is Q21.42
library TickMathPrecision {
    /// @return uint128 in Q63.64
    function getRatioAtTick(int64 tickX42) internal pure returns (uint128) {
        assert(tickX42 >= 0 && tickX42 <= SystemConstants.MAX_TICK_X42);

        uint256 ratioX64 = tickX42 & 0x1 != 0 ? 0x100000000000001A3 : 0x10000000000000000;
        if (tickX42 & 0x2 != 0) ratioX64 = (ratioX64 * 0x10000000000000346) >> 64; // 42th bit after the comma
        if (tickX42 & 0x4 != 0) ratioX64 = (ratioX64 * 0x1000000000000068D) >> 64;
        if (tickX42 & 0x8 != 0) ratioX64 = (ratioX64 * 0x10000000000000D1B) >> 64;
        if (tickX42 & 0x10 != 0) ratioX64 = (ratioX64 * 0x10000000000001A36) >> 64;
        if (tickX42 & 0x20 != 0) ratioX64 = (ratioX64 * 0x1000000000000346D) >> 64;
        if (tickX42 & 0x40 != 0) ratioX64 = (ratioX64 * 0x100000000000068DA) >> 64;
        if (tickX42 & 0x80 != 0) ratioX64 = (ratioX64 * 0x1000000000000D1B4) >> 64;
        if (tickX42 & 0x100 != 0) ratioX64 = (ratioX64 * 0x1000000000001A368) >> 64;
        if (tickX42 & 0x200 != 0) ratioX64 = (ratioX64 * 0x100000000000346D1) >> 64;
        if (tickX42 & 0x400 != 0) ratioX64 = (ratioX64 * 0x10000000000068DA3) >> 64;
        if (tickX42 & 0x800 != 0) ratioX64 = (ratioX64 * 0x100000000000D1B46) >> 64;
        if (tickX42 & 0x1000 != 0) ratioX64 = (ratioX64 * 0x100000000001A368D) >> 64;
        if (tickX42 & 0x2000 != 0) ratioX64 = (ratioX64 * 0x10000000000346D1A) >> 64;
        if (tickX42 & 0x4000 != 0) ratioX64 = (ratioX64 * 0x1000000000068DA34) >> 64;
        if (tickX42 & 0x8000 != 0) ratioX64 = (ratioX64 * 0x10000000000D1B468) >> 64;
        if (tickX42 & 0x10000 != 0) ratioX64 = (ratioX64 * 0x10000000001A368D0) >> 64;
        if (tickX42 & 0x20000 != 0) ratioX64 = (ratioX64 * 0x1000000000346D1A0) >> 64;
        if (tickX42 & 0x40000 != 0) ratioX64 = (ratioX64 * 0x100000000068DA341) >> 64;
        if (tickX42 & 0x80000 != 0) ratioX64 = (ratioX64 * 0x1000000000D1B4683) >> 64;
        if (tickX42 & 0x100000 != 0) ratioX64 = (ratioX64 * 0x1000000001A368D06) >> 64;
        if (tickX42 & 0x200000 != 0) ratioX64 = (ratioX64 * 0x100000000346D1A0C) >> 64;
        if (tickX42 & 0x400000 != 0) ratioX64 = (ratioX64 * 0x10000000068DA3419) >> 64;
        if (tickX42 & 0x800000 != 0) ratioX64 = (ratioX64 * 0x100000000D1B46833) >> 64;
        if (tickX42 & 0x1000000 != 0) ratioX64 = (ratioX64 * 0x100000001A368D066) >> 64;
        if (tickX42 & 0x2000000 != 0) ratioX64 = (ratioX64 * 0x10000000346D1A0D0) >> 64;
        if (tickX42 & 0x4000000 != 0) ratioX64 = (ratioX64 * 0x1000000068DA341AB) >> 64;
        if (tickX42 & 0x8000000 != 0) ratioX64 = (ratioX64 * 0x10000000D1B468381) >> 64;
        if (tickX42 & 0x10000000 != 0) ratioX64 = (ratioX64 * 0x10000001A368D07AF) >> 64;
        if (tickX42 & 0x20000000 != 0) ratioX64 = (ratioX64 * 0x1000000346D1A120E) >> 64;
        if (tickX42 & 0x40000000 != 0) ratioX64 = (ratioX64 * 0x100000068DA342ED9) >> 64;
        if (tickX42 & 0x80000000 != 0) ratioX64 = (ratioX64 * 0x1000000D1B46888A4) >> 64;
        if (tickX42 & 0x100000000 != 0) ratioX64 = (ratioX64 * 0x1000001A368D1BD10) >> 64;
        if (tickX42 & 0x200000000 != 0) ratioX64 = (ratioX64 * 0x100000346D1A62940) >> 64;
        if (tickX42 & 0x400000000 != 0) ratioX64 = (ratioX64 * 0x10000068DA3570F02) >> 64;
        if (tickX42 & 0x800000000 != 0) ratioX64 = (ratioX64 * 0x100000D1B46D9100A) >> 64;
        if (tickX42 & 0x1000000000 != 0) ratioX64 = (ratioX64 * 0x100001A368E5DE82E) >> 64;
        if (tickX42 & 0x2000000000 != 0) ratioX64 = (ratioX64 * 0x10000346D1F6AF0E7) >> 64;
        if (tickX42 & 0x4000000000 != 0) ratioX64 = (ratioX64 * 0x1000068DA49926517) >> 64;
        if (tickX42 & 0x8000000000 != 0) ratioX64 = (ratioX64 * 0x10000D1B4BE16E016) >> 64;
        if (tickX42 & 0x10000000000 != 0) ratioX64 = (ratioX64 * 0x10001A36A27F65E2A) >> 64;
        if (tickX42 & 0x20000000000 != 0) ratioX64 = (ratioX64 * 0x1000346D6FF11672A) >> 64; // 1st bit after the comma
        if (tickX42 & 0x40000000000 != 0) ratioX64 = (ratioX64 * 0x100068DB8BAC710CB) >> 64; // 1st bit before the comma
        if (tickX42 & 0x80000000000 != 0) ratioX64 = (ratioX64 * 0x1000D1B9C68ABE5F7) >> 64;
        if (tickX42 & 0x100000000000 != 0) ratioX64 = (ratioX64 * 0x1001A37E4A234CB08) >> 64;
        if (tickX42 & 0x200000000000 != 0) ratioX64 = (ratioX64 * 0x100347278AB0E92AD) >> 64;
        if (tickX42 & 0x400000000000 != 0) ratioX64 = (ratioX64 * 0x10068EFB00A525480) >> 64;
        if (tickX42 & 0x800000000000 != 0) ratioX64 = (ratioX64 * 0x100D20A63B4173839) >> 64;
        if (tickX42 & 0x1000000000000 != 0) ratioX64 = (ratioX64 * 0x101A4C11C742DD772) >> 64;
        if (tickX42 & 0x2000000000000 != 0) ratioX64 = (ratioX64 * 0x1034C35C31F64CFA6) >> 64;
        if (tickX42 & 0x4000000000000 != 0) ratioX64 = (ratioX64 * 0x106A34B78C8AAFFBF) >> 64;
        if (tickX42 & 0x8000000000000 != 0) ratioX64 = (ratioX64 * 0x10D72A6A46CCD8BCE) >> 64;
        if (tickX42 & 0x10000000000000 != 0) ratioX64 = (ratioX64 * 0x11B9A258E63928596) >> 64;
        if (tickX42 & 0x20000000000000 != 0) ratioX64 = (ratioX64 * 0x13A2E2BDA04F8379F) >> 64;
        if (tickX42 & 0x40000000000000 != 0) ratioX64 = (ratioX64 * 0x181954BE69E0DA8FE) >> 64;
        if (tickX42 & 0x80000000000000 != 0) ratioX64 = (ratioX64 * 0x244C2655D185A0290) >> 64;
        if (tickX42 & 0x100000000000000 != 0) ratioX64 = (ratioX64 * 0x525816EEB9F935B1C) >> 64;
        if (tickX42 & 0x200000000000000 != 0) ratioX64 = (ratioX64 * 0x1A7C8D00B551684FF4) >> 64;
        if (tickX42 & 0x400000000000000 != 0) ratioX64 = (ratioX64 * 0x2BD893D0B2DF7C97884) >> 64;
        if (tickX42 & 0x800000000000000 != 0) ratioX64 = (ratioX64 * 0x78278E1E19E448CF8B95D) >> 64;
        if (tickX42 & 0x1000000000000000 != 0) ratioX64 = (ratioX64 * 0x38651B58D457501416FEADE319) >> 64; // 19th bit before the comma
        // Bits 20 and 21st do not need to be checked because tickX42 <= SystemConstants.MAX_TICK_X42
        // if (tickX42 & 0x2000000000000000 != 0) ratioX64 = (ratioX64 * 0xC6C63E573E99B8B10F5961AE4CACB1F9927) >> 64;
        // if (tickX42 & 0x4000000000000000 != 0)
        //     ratioX64 = (ratioX64 * 0x9A5741F372F8FF89A6E21EE87E9D34BB06995021F74FC62066806D) >> 64; // 21st bit before the comma (1st bit after the comma)

        return uint128(ratioX64);
    }

    /// @return tickX42 Q21.42 (+1 bit for sign)
    /// @notice The result is never negative, but it is returned as an int for compatibilty with negative ticks used outside this library.
    /// @dev We cannot ensure that this function rounds up or down.
    function getTickAtRatio(uint256 num, uint256 den) internal pure returns (int64 tickX42) {
        assert(num >= den);
        assert(den != 0);

        uint256 ratio;
        unchecked {
            ratio = num / den;
        }
        uint256 r = ratio;
        uint256 msb = 0;

        assembly {
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }

        // Normalize to so that it starts at bit 127, and so the square will not overflow
        unchecked {
            if (msb >= 128) r = ratio >> (msb - 127);
            else r = FullMath.mulDiv(num, 2 ** (127 - msb), den);
        }

        // Make space for the decimals
        uint256 log_2 = msb << (42 + 13);

        for (uint256 i = 1; i <= 42 + 13; ++i) {
            assembly {
                r := shr(127, mul(r, r)) // This is product of two Q128.128 numbers, so r is Q128.128
                let f := shr(128, r) // 1 if r≥2, 0 otherwise
                log_2 := or(log_2, shl(sub(55, i), f)) // Add another bit of precision after the comma
                r := shr(f, r)
            }
        }

        return int64(uint64((log_2 * 5311490373674440127006610942261594940696236095528553491154) >> (13 + 179)));
    }
}
