// SPDX-License-Identifier: BUSL 1.1
pragma solidity 0.8.22;

interface Distributable {
    struct DistributionRecord {
        address token;
        address source;
        address repository;
        address depositor;
        string poolName;
        uint256 amount;
        uint256 deadline;
    }

    struct DistributionHistory {
        uint256 distributed;
    }

    error UnsupportedSource();
    error UnsupportedToken();
    error Undistributed();

    event Move(address indexed source, address indexed from, address indexed to, string poolName);

    event Distribution(
        address indexed token,
        address indexed source,
        address indexed depositor,
        address repository,
        string poolName,
        uint256 amount
    );

    function distribute(DistributionRecord calldata distribution, bytes calldata signature) external;

    function distribute(DistributionRecord calldata distribution, address to, bytes calldata signature) external;

    function moveDistribution(address source, string calldata poolName, address from, address to) external;

    function distribution(address source, string calldata poolName, address depositor)
        external
        view
        returns (DistributionHistory memory);

    function nonce(address depositor) external view returns (uint24);
}
