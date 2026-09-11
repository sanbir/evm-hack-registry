// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {ERC721V1} from "./ERC721V1.sol";
import {BurnRegistryV1} from "./burnRegistry/BurnRegistryV1.sol";

contract ERC721V2 is ERC721V1 {
  address payable internal _burnRegistry;

  event ERC721V2BurnRegistryChanged();

  error ERC721V2InvalidBurnRegistry();

  constructor() {
    _disableInitializers();
  }

  function migrateToV2(address payable __burnRegistry) public {
    if (_burnRegistry != address(0)) revert ERC721V2InvalidBurnRegistry();

    _burnRegistry = __burnRegistry;
  }

  function burnRegistry() public view returns (address) {
    return _burnRegistry;
  }

  function changeBurnRegistry(address payable __burnRegistry) public onlyOwner {
    if (__burnRegistry == address(0)) revert ERC721V2InvalidBurnRegistry();

    _burnRegistry = __burnRegistry;

    emit ERC721V2BurnRegistryChanged();
  }

  function burn(uint256 tokenId) public nonReentrant {
    address sender = _msgSender();
    if (ownerOf(tokenId) != sender) revert ERC721V1TransferForbidden();

    _burn(tokenId);
    BurnRegistryV1(_burnRegistry).burn(sender, tokenId);
  }
}
