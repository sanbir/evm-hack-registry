// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import "./interfaces/IConfig.sol";

abstract contract Configurable is Ownable2StepUpgradeable, UUPSUpgradeable, PausableUpgradeable {
    IConfig public config;
    IConfig.Tools public tool;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function __Configurable_init(address _config, IConfig.Tools _tool) internal onlyInitializing {
        __Ownable_init(_msgSender());
        __UUPSUpgradeable_init();
        __Pausable_init();
        __Configurable_init_unchained(_config, _tool);
    }

    function __Configurable_init_unchained(address _config, IConfig.Tools _tool) internal onlyInitializing {
        _updateConfig(_config);
        tool = _tool;
    }

    function updateConfig(address _config) external onlyOwner {
        _updateConfig(_config);
    }

    function _updateConfig(address _newConfig) internal {
        require(_newConfig != address(0), "Configurable: zero address");

        address _oldConfig = address(config);
        config = IConfig(_newConfig);
        emit UpdateConfig(_oldConfig, _newConfig);
    }

    function _fee(address[] memory _whitelist) internal view returns (uint256) {
        if (config.whitelist(_msgSender()) || IERC20(config.token()).balanceOf(_msgSender()) >= config.hodl()) {
            return 0;
        }
        for (uint256 i = 0; i < _whitelist.length; ++i) {
            if (config.whitelist(_whitelist[i])) {
                return 0;
            }
        }
        (uint256 _multisender, uint256 _locker, uint256 _token, ) = config.fees();
        if (tool == IConfig.Tools.MultiSender) {
            return _multisender;
        } else if (tool == IConfig.Tools.Locker) {
            return _locker;
        } else if (tool == IConfig.Tools.Token) {
            return _token;
        } else {
            revert("Configurable: invalid tool");
        }
    }

    function fee() public view returns (uint256) {
        return _fee(new address[](0));
    }

    function fee(address[] memory _whitelist) public view returns (uint256) {
        return _fee(_whitelist);
    }

    event UpdateConfig(address indexed _oldConfig, address indexed _newConfig);
}
