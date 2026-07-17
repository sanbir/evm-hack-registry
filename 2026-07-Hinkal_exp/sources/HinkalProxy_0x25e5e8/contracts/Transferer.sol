// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./TransfererBase.sol";

contract Transferer is TransfererBase {
    using SafeERC20 for IERC20;

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) public pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function unsafeApproveERC20Token(
        address _erc20TokenAddress,
        address _to,
        uint256 _value
    ) internal {
        IERC20(_erc20TokenAddress).approve(_to, 0);
        IERC20(_erc20TokenAddress).approve(_to, _value);
    }

    function getERC20Allowance(
        address _erc20TokenAddress,
        address owner,
        address spender
    ) internal view returns (uint256) {
        IERC20 outToken = IERC20(_erc20TokenAddress);
        return outToken.allowance(owner, spender);
    }

    function approveERC721Token(
        address _erc20TokenAddress,
        address _to,
        uint256 _tokenId
    ) internal {
        IERC721(_erc20TokenAddress).approve(_to, _tokenId);
    }

    function approveToken(
        address _erc20TokenAddress,
        address _to,
        uint256 _tokenId,
        uint256 _value
    ) internal {
        if (_tokenId == 0) {
            unsafeApproveERC20Token(_erc20TokenAddress, _to, _value);
        } else {
            approveERC721Token(_erc20TokenAddress, _to, _tokenId);
        }
    }

    function transferERC20TokenFrom(
        address _erc20TokenAddress,
        address _from,
        address _to,
        uint256 _value
    ) internal {
        IERC20(_erc20TokenAddress).safeTransferFrom(_from, _to, _value);
    }

    function transferNftFrom(
        address _erc20TokenAddress,
        address _from,
        address _to,
        uint256 _tokenId
    ) internal {
        IERC721(_erc20TokenAddress).safeTransferFrom(_from, _to, _tokenId);
    }

    function transferERC20TokenOrETH(
        address _erc20TokenAddress,
        address _to,
        uint256 _value
    ) internal {
        if (_erc20TokenAddress == address(0)) {
            transferETH(_to, _value);
        } else {
            transferERC20Token(_erc20TokenAddress, _to, _value);
        }
    }

    function transferToken(
        address _erc20TokenAddress,
        address _to,
        uint256 _value,
        uint256 _tokenId
    ) internal {
        if (_tokenId == 0) {
            transferERC20TokenOrETH(_erc20TokenAddress, _to, _value);
        } else {
            transferNftFrom(_erc20TokenAddress, address(this), _to, _tokenId);
        }
    }

    function multiTransfer(
        address[] memory erc20TokenAddresses,
        address _to,
        uint256[] memory amounts
    ) internal returns (bool) {
        for (uint64 i = 0; i < erc20TokenAddresses.length; i++) {
            if (amounts[i] > 0)
                transferERC20TokenOrETH(
                    erc20TokenAddresses[i],
                    _to,
                    amounts[i]
                );
        }
        return true;
    }

    function transferERC20TokenFromOrCheckETH(
        address _contractAddress,
        address _from,
        address _to,
        uint256 _value
    ) internal {
        if (_contractAddress == address(0)) {
            require(
                msg.value == _value,
                "msg.value doesn't match needed amount"
            );
            if (_to != address(this)) {
                transferETH(_to, _value);
            }
        } else {
            transferERC20TokenFrom(_contractAddress, _from, _to, _value);
        }
    }

    function transferTokenFrom(
        address _erc20TokenAddress,
        address _from,
        address _to,
        uint256 _value,
        uint256 _tokenId
    ) internal {
        if (_tokenId == 0) {
            transferERC20TokenFromOrCheckETH(
                _erc20TokenAddress,
                _from,
                _to,
                _value
            );
        } else {
            transferNftFrom(_erc20TokenAddress, _from, _to, _tokenId);
        }
    }

    function multiTransferFrom(
        address[] memory erc20TokenAddresses,
        address _from,
        address _to,
        uint256[] memory amounts
    ) internal returns (bool) {
        for (uint64 i = 0; i < erc20TokenAddresses.length; i++) {
            if (amounts[i] > 0) {
                transferERC20TokenFromOrCheckETH(
                    erc20TokenAddresses[i],
                    _from,
                    _to,
                    amounts[i]
                );
            }
        }
        return true;
    }

    function getERC20OrETHBalance(
        address _erc20TokenAddress
    ) internal view returns (uint256) {
        if (_erc20TokenAddress == address(0)) {
            return address(this).balance;
        } else {
            IERC20 outToken = IERC20(_erc20TokenAddress);
            return outToken.balanceOf(address(this));
        }
    }

    function getNftBalance(
        address _erc20TokenAddress,
        uint256 tokenId
    ) internal view returns (uint256) {
        IERC721 outToken = IERC721(_erc20TokenAddress);
        try outToken.ownerOf(tokenId) returns (address owner) {
            if (owner == address(this)) return 1;
            else return 0;
        } catch {
            return 0;
        }
    }

    function getBalancesForArrayMemory(
        address[] memory erc20TokenAddresses
    ) internal view returns (uint256[] memory balances) {
        balances = new uint256[](erc20TokenAddresses.length);
        for (uint64 i; i < erc20TokenAddresses.length; i++) {
            balances[i] = getERC20OrETHBalance(erc20TokenAddresses[i]);
        }
    }

    function getBalancesForArrayMemory(
        address[] memory erc20TokenAddresses,
        uint256[] memory tokenIds
    ) internal view returns (uint256[] memory balances) {
        balances = new uint256[](erc20TokenAddresses.length);
        for (uint64 i; i < erc20TokenAddresses.length; i++) {
            if (tokenIds[i] == 0) {
                balances[i] = getERC20OrETHBalance(erc20TokenAddresses[i]);
            } else {
                balances[i] = getNftBalance(
                    erc20TokenAddresses[i],
                    tokenIds[i]
                );
            }
        }
    }

    function getBalancesForArray(
        address[] calldata erc20TokenAddresses
    ) internal view returns (uint256[] memory balances) {
        balances = new uint256[](erc20TokenAddresses.length);
        for (uint64 i; i < erc20TokenAddresses.length; i++) {
            balances[i] = getERC20OrETHBalance(erc20TokenAddresses[i]);
        }
    }

    function getBalancesForArray(
        address[] calldata erc20TokenAddresses,
        uint256[] calldata tokenIds
    ) internal view returns (uint256[] memory balances) {
        balances = new uint256[](erc20TokenAddresses.length);
        for (uint64 i; i < erc20TokenAddresses.length; i++) {
            if (tokenIds[i] == 0) {
                balances[i] = getERC20OrETHBalance(erc20TokenAddresses[i]);
            } else {
                balances[i] = getNftBalance(
                    erc20TokenAddresses[i],
                    tokenIds[i]
                );
            }
        }
    }

    function sendToRelay(
        address relay,
        uint256 actualAmount,
        address erc20TokenAddress
    ) internal {
        if (relay != address(0) && actualAmount > 0) {
            transferERC20TokenOrETH(
                erc20TokenAddress,
                relay,
                uint256(actualAmount)
            );
        }
    }
}
