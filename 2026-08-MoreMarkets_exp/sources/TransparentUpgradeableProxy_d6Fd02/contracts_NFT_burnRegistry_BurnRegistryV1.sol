// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPriceFeed} from "../../interfaces/IPriceFeed.sol";

contract BurnRegistryV1 is OwnableUpgradeable, PausableUpgradeable {
  address internal _token;

  mapping(uint256 => address) internal _burned;

  mapping(address => uint16) internal _burnedCount;

  mapping(address => bool) internal _winner;

  mapping(address => bool) internal _distributors;

  uint256 internal _totalSupply;

  uint256 internal _recoverUSD;

  address internal _priceFeed;

  event Burned(address indexed wallet, uint256 tokenId, uint256 index);
  event RecoverChanged(uint256 oldRecoverUSD, uint256 newRecoverUSD);
  event Withdrawal(address indexed recipient, uint256 amount);
  event Winner(address indexed wallet);
  event ChangeDistributor(address indexed distributor, bool isAdded);

  error BurnRegistryInvalidSender(address sender);
  error BurnRegistryNegativePrice(int256 price);
  error BurnRegistryTransferFailed(address wallet, uint256 amount);
  error BurnRegistryInvalidDistributor(address distributor);

  constructor() {
    _disableInitializers();
  }

  function initialize(address __token, address __priceFeed, uint256 __recoverUSD) public initializer {
    __Ownable_init(_msgSender());
    __Pausable_init();
    _token = __token;
    _priceFeed = __priceFeed;
    _recoverUSD = __recoverUSD;
  }

  receive() external payable {}

  fallback() external payable {}

  function pause() external onlyOwner {
    _pause();
  }

  function unpause() external onlyOwner {
    _unpause();
  }

  function addDistributor(address distributor) external onlyOwner {
    _distributors[distributor] = true;
    emit ChangeDistributor(distributor, true);
  }

  function removeDistributor(address distributor) external onlyOwner {
    _distributors[distributor] = false;
    emit ChangeDistributor(distributor, false);
  }

  function token() public view returns (address) {
    return _token;
  }

  function totalSupply() public view returns (uint256) {
    return _totalSupply;
  }

  function burnedBy(uint256 index) public view returns (address) {
    return _burned[index];
  }

  function burnedCount(address wallet) public view returns (uint16) {
    return _burnedCount[wallet];
  }

  function isWinner(address wallet) public view returns (bool) {
    return _winner[wallet];
  }

  function recoverUSD() public view returns (uint256) {
    return _recoverUSD;
  }

  function changeRecover(uint256 newRecoverUSD) public onlyOwner {
    uint256 oldRecoverUSD = _recoverUSD;
    _recoverUSD = newRecoverUSD;
    emit RecoverChanged(oldRecoverUSD, newRecoverUSD);
  }

  function recoverETH() public view returns (uint256) {
    (, int256 price, , , ) = IPriceFeed(_priceFeed).latestRoundData();
    if (price <= 0) {
      revert BurnRegistryNegativePrice(price);
    }

    return (_recoverUSD * (10 ** IPriceFeed(_priceFeed).decimals())) / uint256(price);
  }

  function burn(address wallet, uint256 tokenId) external whenNotPaused {
    address sender = _msgSender();
    if (sender != _token) revert BurnRegistryInvalidSender(sender);

    uint256 index = _totalSupply++;
    _burned[index] = wallet;
    _burnedCount[wallet] += 1;

    uint256 recover = recoverETH();
    (bool sent, ) = payable(wallet).call{value: recover}("");
    if (!sent) revert BurnRegistryTransferFailed(wallet, recover);

    emit Burned(wallet, tokenId, index);
  }

  function winner(address wallet) external {
    address distributor = _msgSender();
    if (!_distributors[distributor]) {
      revert BurnRegistryInvalidDistributor(distributor);
    }

    _winner[wallet] = true;
    emit Winner(wallet);
  }

  function withdrawCrumbs(address payable recipient, uint256 amount) public onlyOwner whenPaused {
    (bool sent, ) = recipient.call{value: amount}("");
    if (!sent) revert BurnRegistryTransferFailed(recipient, amount);

    emit Withdrawal(recipient, amount);
  }
}
