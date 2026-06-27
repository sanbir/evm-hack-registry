// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ITunnelHub {
    function HUB_ID() external view returns (uint8);
    function upgradeTunnel(string memory, bool, uint64) external returns (address);
}

contract Constants {
    uint64 public immutable VERSION;
    address public immutable HUB_ADDRESS;
    bytes32 internal immutable TUNNEL_NAME_BYTES;
    uint8 internal immutable TUNNEL_NAME_LEN;
    bool internal immutable IS_LOCK_MODE;

    uint256 constant PROPOSE_PERIOD = 48 hours;
    uint256 constant EXPIRE_PERIOD = 72 hours;
    uint256 constant EXPIRE_EXTRA_PERIOD = 96 hours;

    constructor(uint64 version, address hubAddress, string memory tunnelName, bool isLockMode) {
        VERSION = version;
        HUB_ADDRESS = hubAddress;
        IS_LOCK_MODE = isLockMode;

        bytes memory nameBytes = bytes(tunnelName);
        uint256 len = nameBytes.length;
        require(len < 32, "The length of tunnelName must be less than 32.");
        bytes32 nameBytes32;
        assembly {
            nameBytes32 := mload(add(nameBytes, 32))
        }
        TUNNEL_NAME_BYTES = nameBytes32;
        TUNNEL_NAME_LEN = uint8(len);
    }

    function HUB_ID() public view returns (uint8) {
        return ITunnelHub(HUB_ADDRESS).HUB_ID();
    }

    function getTunnelName() public view returns (string memory tunnelName) {
        bytes32 nameBytes = TUNNEL_NAME_BYTES;
        tunnelName = new string(TUNNEL_NAME_LEN);
        assembly {
            mstore(add(tunnelName, 32), nameBytes)
        }
    }

    modifier onlyHub() {
        require(msg.sender == HUB_ADDRESS, "Only for FreeTunnelHub");
        _;
    }
}
