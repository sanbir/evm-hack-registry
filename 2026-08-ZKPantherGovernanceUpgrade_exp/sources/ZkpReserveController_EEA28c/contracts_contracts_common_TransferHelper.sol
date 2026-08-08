// SPDX-License-Identifier: GPL-3.0-or-later
// solhint-disable avoid-low-level-calls
// solhint-disable no-inline-assembly
// slither-disable-next-line solc-version
pragma solidity ^0.8.4;

/// @title TransferHelper library
/// @dev Helper methods for interacting with ERC20, ERC721, ERC1155 tokens and sending ETH
/// Based on the Uniswap/solidity-lib/contracts/libraries/TransferHelper.sol
library TransferHelper {
    /// @dev Throws if the deployed code of the `token` is empty.
    // Low-level CALL to a non-existing contract returns `success` of 1 and empty `data`.
    // It may be misinterpreted as a successful call to a deployed token contract.
    // So, the code calling a token contract must insure the contract code exists.
    modifier onlyDeployedToken(address token) {
        require(isDeployedContract(token), "TransferHelper: zero codesize");
        _;
    }

    /// @dev Return true if the given account has deployed code
    function isDeployedContract(address account) internal view returns (bool) {
        uint256 codeSize;
        // slither-disable-next-line assembly
        assembly {
            codeSize := extcodesize(account)
        }
        return codeSize > 0;
    }

    /// @dev Approve the `operator` to spend all of ERC720 tokens on behalf of `owner`.
    function safeSetApprovalForAll(
        address token,
        address operator,
        bool approved
    ) internal onlyDeployedToken(token) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.call(
            // bytes4(keccak256('setApprovalForAll(address,bool)'));
            abi.encodeWithSelector(0xa22cb465, operator, approved)
        );
        _requireSuccess(success, data);
    }

    /// @dev Get the ERC20 balance of `account`
    function safeBalanceOf(
        address token,
        address account
    ) internal view returns (uint256 balance) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.staticcall(
            // bytes4(keccak256(bytes('balanceOf(address)')));
            abi.encodeWithSelector(0x70a08231, account)
        );
        require(
            // since `data` can't be empty, `onlyDeployedToken` unneeded
            success && (data.length != 0),
            "TransferHelper: balanceOf call failed"
        );

        balance = abi.decode(data, (uint256));
    }

    /// @dev Get the owner of the ERC-721 token
    function safe721OwnerOf(
        address token,
        uint256 tokenId
    ) internal view returns (address owner) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.staticcall(
            // bytes4(keccak256(bytes('ownerOf(uint256)')));
            abi.encodeWithSelector(0x6352211e, tokenId)
        );
        require(
            // since `data` can't be empty, `onlyDeployedToken` unneeded
            success && (data.length != 0),
            "TransferHelper: ownerOf call failed"
        );
        owner = abi.decode(data, (address));
    }

    /// @dev Get the ERC-1155 token balance of `account`
    function safe1155BalanceOf(
        address token,
        address account,
        uint256 tokenId
    ) internal view returns (uint256 balance) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.staticcall(
            // bytes4(keccak256(bytes('balanceOf(address,uint256)')));
            abi.encodeWithSelector(0x00fdd58e, account, tokenId)
        );
        require(
            // since `data` can't be empty, `onlyDeployedToken` unneeded
            success && (data.length != 0),
            "TransferHelper: balanceOf call failed"
        );
        balance = abi.decode(data, (uint256));
    }

    /// @dev Get the ERC20 allowance of `spender`
    function safeAllowance(
        address token,
        address owner,
        address spender
    ) internal view onlyDeployedToken(token) returns (uint256 allowance) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.staticcall(
            // bytes4(keccak256("allowance(address,address)"));
            abi.encodeWithSelector(0xdd62ed3e, owner, spender)
        );
        require(
            // since `data` can't be empty, `onlyDeployedToken` unneeded
            success && (data.length != 0),
            "TransferHelper: allowance call failed"
        );

        allowance = abi.decode(data, (uint256));
    }

    /// @dev Approve the `spender` to spend the `amount` of ERC20 token on behalf of `owner`.
    function safeApprove(
        address token,
        address to,
        uint256 value
    ) internal onlyDeployedToken(token) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.call(
            // bytes4(keccak256('approve(address,uint256)'));
            abi.encodeWithSelector(0x095ea7b3, to, value)
        );
        _requireSuccess(success, data);
    }

    /// @dev Increase approval of the `spender` to spend the `amount` of ERC20 token on behalf of `owner`.
    function safeIncreaseAllowance(
        address token,
        address to,
        uint256 value
    ) internal onlyDeployedToken(token) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.call(
            // bytes4(keccak256("increaseAllowance(address,uint256)"));
            abi.encodeWithSelector(0x39509351, to, value)
        );
        _requireSuccess(success, data);
    }

    /// @dev Transfer `value` ERC20 tokens from caller to `to`.
    function safeTransfer(
        address token,
        address to,
        uint256 value
    ) internal onlyDeployedToken(token) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.call(
            // bytes4(keccak256('transfer(address,uint256)'));
            abi.encodeWithSelector(0xa9059cbb, to, value)
        );
        _requireSuccess(success, data);
    }

    /// @dev Transfer `value` ERC20 tokens on behalf of `from` to `to`.
    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
    ) internal onlyDeployedToken(token) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.call(
            // bytes4(keccak256('transferFrom(address,address,uint256)'));
            abi.encodeWithSelector(0x23b872dd, from, to, value)
        );
        _requireSuccess(success, data);
    }

    /// @dev Transfer an ERC721 token with id of `tokenId` on behalf of `from` to `to`.
    function erc721SafeTransferFrom(
        address token,
        uint256 tokenId,
        address from,
        address to
    ) internal onlyDeployedToken(token) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.call(
            // bytes4(keccak256('safeTransferFrom(address,address,uint256)'));
            abi.encodeWithSelector(0x42842e0e, from, to, tokenId)
        );
        _requireSuccess(success, data);
    }

    /// @dev Transfer `amount` ERC1155 token with id of `tokenId` on behalf of `from` to `to`.
    function erc1155SafeTransferFrom(
        address token,
        address from,
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes memory _data
    ) internal onlyDeployedToken(token) {
        // slither-disable-next-line low-level-calls
        (bool success, bytes memory data) = token.call(
            // bytes4(keccak256('safeTransferFrom(address,address,uint256,uint256,bytes)'));
            abi.encodeWithSelector(0xf242432a, from, to, tokenId, amount, _data)
        );
        _requireSuccess(success, data);
    }

    /// @dev Get the Native balance of `_contract`
    function safeContractBalance(
        address _contract
    ) internal view returns (uint256) {
        require(
            isDeployedContract(_contract),
            "TransferHelper: Only contract address"
        );
        return _contract.balance;
    }

    /// @dev Transfer `value` Ether from caller to `to`.
    function safeTransferETH(address to, uint256 value) internal {
        // slither-disable-next-line low-level-calls
        (bool success, ) = to.call{ value: value }(new bytes(0));
        require(success, "TransferHelper: ETH transfer failed");
    }

    function _requireSuccess(bool success, bytes memory res) private pure {
        require(
            success && (res.length == 0 || abi.decode(res, (bool))),
            "TransferHelper: token contract call failed"
        );
    }
}
