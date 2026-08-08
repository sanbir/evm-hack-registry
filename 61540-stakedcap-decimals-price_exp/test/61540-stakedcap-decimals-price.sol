// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract StakedCapAdapter {
    function price(uint256 rawPrice, uint8 capTokenDecimals, uint8 stakedTokenDecimals)
        public
        pure
        returns (uint256)
    {
        // @> VULN: decimal counts are used instead of 10 ** decimal scaling factors.
        return rawPrice * capTokenDecimals / stakedTokenDecimals;
    }

    function correctedPrice(uint256 rawPrice, uint8 capTokenDecimals, uint8 stakedTokenDecimals)
        public
        pure
        returns (uint256)
    {
        return rawPrice * (10 ** capTokenDecimals) / (10 ** stakedTokenDecimals);
    }
}

contract Exploit {
    StakedCapAdapter public adapter;
    uint256 public wrong;
    uint256 public expected;
    bool public confirmed;

    constructor() {
        adapter = new StakedCapAdapter();
    }

    function run() external {
        wrong = adapter.price(2e18, 6, 18);
        expected = adapter.correctedPrice(2e18, 6, 18);
        require(wrong != expected, "decimal mismatch not reproduced");
        require(expected == 2e6, "reference normalization mismatch");
        require(wrong == 666666666666666666, "wrong decimal-count result changed");
        confirmed = true;
    }
}

