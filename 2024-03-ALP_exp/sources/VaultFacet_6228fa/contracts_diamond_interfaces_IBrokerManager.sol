// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

struct CommissionInfo {
    address token;
    uint total;
    uint pending;
}

interface IBrokerManager {

    struct BrokerInfo {
        string name;
        string url;
        address receiver;
        uint24 id;
        uint16 commissionP;
        uint16 daoShareP;
        uint16 alpPoolP;
        CommissionInfo[] commissions;
    }

    function addBroker(
        uint24 id, uint16 commissionP, uint16 daoShareP, uint16 alpPoolP,
        address receiver, string calldata name, string calldata url
    ) external;

    function removeBroker(uint24 id) external;

    function updateBrokerCommissionP(uint24 id, uint16 commissionP, uint16 daoShareP, uint16 alpPoolP) external;

    function updateBrokerReceiver(uint24 id, address receiver) external;

    function updateBrokerName(uint24 id, string calldata name) external;

    function updateBrokerUrl(uint24 id, string calldata url) external;

    function getBrokerById(uint24 id) external view returns (BrokerInfo memory);

    function brokers(uint start, uint8 length) external view returns (BrokerInfo[] memory);

    function withdrawCommission(uint24 id) external;
}
