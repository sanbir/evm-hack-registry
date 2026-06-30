// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../interfaces/giddy/IGiddyDefiAdapter.sol";
import "./GiddyStrategyFactory.sol";

contract GiddyAdapterManager is Initializable, OwnableUpgradeable {
  using SafeERC20 for IERC20;

  address public strategyFactory;
  mapping(address => bytes32) public tokenMap;
  mapping(bytes32 => address) public adapterMap;

  event AdapterSet(string adapterName, address adapterAddress);
  event TokenAdapterSet(address token, string adapterName);

  error NotManager();
  error InvalidAdapter();

  function initialize(address _strategyFactory) public initializer {
    __Ownable_init(_msgSender());
    strategyFactory = _strategyFactory;
  }

  modifier onlyManager() {
    if (!GiddyStrategyFactory(strategyFactory).keepers(msg.sender)) revert NotManager();
    _;
  }

  function getBaseTokens(address defiToken) external view returns (address[] memory tokens) {
    address adapter = getTokenAdapter(defiToken);
    if (adapter == address(0)) {
      tokens = new address[](1);
      tokens[0] = defiToken;
    } else {
      tokens = IGiddyDefiAdapter(adapter).getBaseTokens(defiToken);
    }
  }

  function getBaseRatios(address defiToken) external view returns (uint256[] memory ratios) {
    address adapter = getTokenAdapter(defiToken);
    if (adapter == address(0)) {
      ratios = new uint256[](1);
      ratios[0] = 1e18; // 100% ratio
    } else {
      ratios = IGiddyDefiAdapter(adapter).getBaseRatios(defiToken);
    }
  }

  function getBaseAmounts(address defiToken, uint defiAmount) external view returns (uint256[] memory baseAmounts) {
    address adapter = getTokenAdapter(defiToken);
    if (adapter == address(0)) {
      baseAmounts = new uint256[](1);
      baseAmounts[0] = defiAmount;
    } else {
      baseAmounts = IGiddyDefiAdapter(adapter).getBaseAmounts(defiToken, defiAmount);
    }
  }

  function getGrowthIndex(address defiToken) external view returns (uint256 index) {
    address adapter = getTokenAdapter(defiToken);
    if (adapter == address(0)) {
      index = 1e18; // Return 1:1 ratio if no adapter
    } else {
      index = IGiddyDefiAdapter(adapter).getGrowthIndex(defiToken);
    }
  }

  function setAdapter(string memory adapterName, address adapterAddress) public onlyManager {
    if (bytes(adapterName).length == 0) revert InvalidAdapter();
    adapterMap[keccak256(bytes(adapterName))] = adapterAddress;
    emit AdapterSet(adapterName, adapterAddress);
  }

  function getAdapter(string memory adapterName) public view returns (address adapterAddress) {
    return adapterMap[keccak256(bytes(adapterName))];
  }

  function setTokenAdapter(address token, string memory adapterName) public onlyManager {
    if (bytes(adapterName).length == 0) revert InvalidAdapter();
    tokenMap[token] = keccak256(bytes(adapterName));
    emit TokenAdapterSet(token, adapterName);
  }

  function getTokenAdapter(address token) public view returns (address adapterAddress) {
    return adapterMap[tokenMap[token]];
  }

  function hasAdapter(address token) public view returns (bool) {
    return adapterMap[tokenMap[token]] != address(0);
  }
}