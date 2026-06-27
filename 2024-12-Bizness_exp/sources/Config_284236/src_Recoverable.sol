// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract Recoverable is Ownable2StepUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function __Recoverable_init() internal onlyInitializing {
        __Ownable_init(_msgSender());
        __UUPSUpgradeable_init();
        __Recoverable_init_unchained();
    }

    function __Recoverable_init_unchained() internal onlyInitializing {}

    function recoverTokens(address _token, uint256 _amount, address _to) external onlyOwner {
        IERC20(_token).safeTransfer(_to, _amount);
        emit TokensRecovered(_token, _amount, _to);
    }

    function recoverNFT(address _token, uint256 _tokenId, address _to) external onlyOwner {
        IERC721(_token).safeTransferFrom(address(this), _to, _tokenId);
        emit NFTRecovered(_token, _tokenId, _to);
    }

    function recoverEth(uint256 _amount, address payable _to) external onlyOwner {
        _to.transfer(_amount);
        emit EthRecovered(_amount, _to);
    }

    event TokensRecovered(address indexed _token, uint256 indexed _amount, address indexed _to);
    event NFTRecovered(address indexed _token, uint256 indexed _tokenId, address indexed _to);
    event EthRecovered(uint256 indexed _amount, address indexed _to);
}
