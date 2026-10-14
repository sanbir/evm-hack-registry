// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import { Base } from "../common/Base.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "../interfaces/IZooKeeper.sol";

// Pellar + LightLink 2022

contract TRVZooKeeper is Base, IZooKeeper, ERC721Holder, ERC1155Holder {
  function transferERC20In(
    address _currency,
    address _from,
    uint256 _amount
  ) external override onlyRoler("transferERC20In") {
    IERC20(_currency).transferFrom(_from, address(this), _amount);
  }

  function transferERC20Out(
    address _currency,
    address _to,
    uint256 _amount
  ) external override onlyRoler("transferERC20Out") {
    IERC20(_currency).transfer(_to, _amount);
  }

  function transferERC721In(
    address _currency,
    address _from,
    uint256 _tokenId
  ) external override onlyRoler("transferERC721In") {
    IERC721(_currency).transferFrom(_from, address(this), _tokenId);
  }

  function transferERC721Out(
    address _currency,
    address _to,
    uint256 _tokenId
  ) external override onlyRoler("transferERC721Out") {
    IERC721(_currency).transferFrom(address(this), _to, _tokenId);
  }

  function transferERC1155In(
    address _currency,
    address _from,
    uint256 _id,
    uint256 _amount
  ) external override onlyRoler("transferERC1155In") {
    IERC1155(_currency).safeTransferFrom(_from, address(this), _id, _amount, '');
  }

  function transferERC1155Out(
    address _currency,
    address _to,
    uint256 _id,
    uint256 _amount
  ) external override onlyRoler("transferERC1155Out") {
    IERC1155(_currency).safeTransferFrom(address(this), _to, _id, _amount, '');
  }
}
