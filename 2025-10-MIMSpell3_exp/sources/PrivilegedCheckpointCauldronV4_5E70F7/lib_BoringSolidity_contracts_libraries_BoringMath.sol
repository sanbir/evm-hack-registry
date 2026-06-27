// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

library BoringMath {
    error ErrOverflow();

    function add(uint256 a, uint256 b) internal pure returns (uint256) {
        return a + b;
    }

    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a - b;
    }

    function mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return a * b;
    }

    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        return a / b;
    }

    function to32(uint256 a) internal pure returns (uint32) {
        if (a > type(uint32).max) {
            revert ErrOverflow();
        }
        return uint32(a);
    }

    function to40(uint256 a) internal pure returns (uint40) {
        if (a > type(uint40).max) {
            revert ErrOverflow();
        }
        return uint40(a);
    }

    function to64(uint256 a) internal pure returns (uint64) {
        if (a > type(uint64).max) {
            revert ErrOverflow();
        }
        return uint64(a);
    }

    function to112(uint256 a) internal pure returns (uint112) {
        if (a > type(uint112).max) {
            revert ErrOverflow();
        }
        return uint112(a);
    }

    function to128(uint256 a) internal pure returns (uint128) {
        if (a > type(uint128).max) {
            revert ErrOverflow();
        }
        return uint128(a);
    }

    function to208(uint256 a) internal pure returns (uint208) {
        if (a > type(uint208).max) {
            revert ErrOverflow();
        }
        return uint208(a);
    }

    function to216(uint256 a) internal pure returns (uint216) {
        if (a > type(uint216).max) {
            revert ErrOverflow();
        }
        return uint216(a);
    }

    function to224(uint256 a) internal pure returns (uint224) {
        if (a > type(uint224).max) {
            revert ErrOverflow();
        }
        return uint224(a);
    }
}

library BoringMath32 {
    function add(uint32 a, uint32 b) internal pure returns (uint32) {
        return a + b;
    }

    function sub(uint32 a, uint32 b) internal pure returns (uint32) {
        return a - b;
    }

    function mul(uint32 a, uint32 b) internal pure returns (uint32) {
        return a * b;
    }

    function div(uint32 a, uint32 b) internal pure returns (uint32) {
        return a / b;
    }
}

library BoringMath64 {
    function add(uint64 a, uint64 b) internal pure returns (uint64) {
        return a + b;
    }

    function sub(uint64 a, uint64 b) internal pure returns (uint64) {
        return a - b;
    }

    function mul(uint64 a, uint64 b) internal pure returns (uint64) {
        return a * b;
    }

    function div(uint64 a, uint64 b) internal pure returns (uint64) {
        return a / b;
    }
}

library BoringMath112 {
    function add(uint112 a, uint112 b) internal pure returns (uint112) {
        return a + b;
    }

    function sub(uint112 a, uint112 b) internal pure returns (uint112) {
        return a - b;
    }

    function mul(uint112 a, uint112 b) internal pure returns (uint112) {
        return a * b;
    }

    function div(uint112 a, uint112 b) internal pure returns (uint112) {
        return a / b;
    }
}

library BoringMath128 {
    function add(uint128 a, uint128 b) internal pure returns (uint128) {
        return a + b;
    }

    function sub(uint128 a, uint128 b) internal pure returns (uint128) {
        return a - b;
    }

    function mul(uint128 a, uint128 b) internal pure returns (uint128) {
        return a * b;
    }

    function div(uint128 a, uint128 b) internal pure returns (uint128) {
        return a / b;
    }
}

library BoringMath224 {
    function add(uint224 a, uint224 b) internal pure returns (uint224) {
        return a + b;
    }

    function sub(uint224 a, uint224 b) internal pure returns (uint224) {
        return a - b;
    }

    function mul(uint224 a, uint224 b) internal pure returns (uint224) {
        return a * b;
    }

    function div(uint224 a, uint224 b) internal pure returns (uint224) {
        return a / b;
    }
}
