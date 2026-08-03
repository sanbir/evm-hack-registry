// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OFTUpgradeable} from "layerzero-v2/oapp/contracts/oft/OFTUpgradeable.sol";

contract TestUSDT is
    Initializable,
    OFTUpgradeable,
    UUPSUpgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable
{
    mapping(address => bool) private whitelist; //!
    uint32 private dstEid;

    function initialize(
        address _lzEndpoint,
        address _delegate
    ) public initializer {
        __OFT_init("Test Tether", "TUSDT", _lzEndpoint, _delegate);
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function setDstEid(uint32 _eid) external onlyOwner {
        require(_eid != 0, "EID can't be zero");
        dstEid = _eid;
    }

    function pause() public onlyOwner {
        _pause();
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function mint(address to, uint256 amount) public returns (bool) {
        _mint(to, amount);
        return true;
    }

    function burnFromUser(address to, uint256 amount) public returns (bool) {
        burnFrom(to, amount);
        return true;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        super._update(from, to, value);
    }
}
