// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Registry is OwnableUpgradeable {
    mapping(string => address) public registry;

    function initialize() external initializer {
        __Ownable_init(msg.sender);
    }

    function setContractAddress(
        string memory _name,
        address _address
    ) external onlyOwner {
        registry[_name] = _address;
    }

    function getContractAddress(
        string memory _name
    ) external view returns (address) {
        require(registry[_name] != address(0), "Registry :: Address not found");
        return registry[_name];
    }
}
