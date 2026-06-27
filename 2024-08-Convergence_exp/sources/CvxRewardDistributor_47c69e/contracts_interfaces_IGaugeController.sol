// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGaugeController {
    struct WeightType {
        uint256 weight;
        uint256 type_weight;
        int128 gauge_type;
    }

    function add_type(string memory typeName, uint256 weight) external;

    function add_gauge(address addr, int128 gaugeType, uint256 weight) external;

    function get_gauge_weight(address gaugeAddress) external view returns (uint256);

    function get_gauge_weights(address[] memory gaugeAddresses) external view returns (uint256[] memory, uint256);

    function get_gauge_weights_and_types(address[] memory gaugeAddresses) external view returns (WeightType[] memory);

    function get_total_weight() external view returns (uint256);

    function n_gauges() external view returns (uint128);

    function gauges(uint256 index) external view returns (address);

    function gauge_types(address gaugeAddress) external view returns (int128);

    function get_type_weight(int128 typeId) external view returns (uint256);

    function gauge_relative_weight(address addr, uint256 time) external view returns (uint256);

    function set_lock(bool isLock) external;

    function gauge_relative_weight_write(address gaugeAddress) external;

    function gauge_relative_weight_writes(uint256 from, uint256 length) external;

    function simple_vote(uint256 tokenId, address gaugeAddress, uint256 tokenWeight) external;
}
