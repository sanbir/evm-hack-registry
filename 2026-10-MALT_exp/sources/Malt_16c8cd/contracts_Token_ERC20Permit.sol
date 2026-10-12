// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "openzeppelin/token/ERC20/ERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/utils/cryptography/draft-EIP712.sol";

interface ITransferReceiver {
  function onTokenTransfer(
    address,
    uint256,
    bytes calldata
  ) external returns (bool);
}

interface IApprovalReceiver {
  function onTokenApproval(
    address,
    uint256,
    bytes calldata
  ) external returns (bool);
}

contract ERC20Permit is ERC20, EIP712, IERC20Permit {
  bytes32 public constant PERMIT_TYPEHASH =
    keccak256(
      "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
    );
  bytes32 public constant TRANSFER_TYPEHASH =
    keccak256(
      "Transfer(address owner,address to,uint256 value,uint256 nonce,uint256 deadline)"
    );

  /// Every successful call to {permit} increases account's nonce by one. This prevents signature from being used multiple times.
  mapping(address => uint256) public override nonces;

  constructor(string memory name, string memory ticker)
    ERC20(name, ticker)
    EIP712(name, "1")
  {}

  function DOMAIN_SEPARATOR() public view override returns (bytes32) {
    return _domainSeparatorV4();
  }

  /// Requirements:
  ///   - `deadline` must be timestamp in future.
  ///   - `v`, `r` and `s` must be valid `secp256k1` signature from `owner` account over EIP712-formatted function arguments.
  ///   - the signature must use `owner` account's current nonce (see {nonces}).
  ///   - the signer cannot be zero address and must be `owner` account.
  function permit(
    address target,
    address spender,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external override {
    require(block.timestamp <= deadline, "ERC20Permit: Expired permit");

    bytes32 hashStruct = keccak256(
      abi.encode(
        PERMIT_TYPEHASH,
        target,
        spender,
        value,
        nonces[target]++,
        deadline
      )
    );

    require(
      verifyEIP712(target, hashStruct, v, r, s) ||
        verifyPersonalSign(target, hashStruct, v, r, s),
      "invalide EIP712 #1"
    );

    _approve(target, spender, value);
  }

  function transferWithPermit(
    address target,
    address to,
    uint256 value,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external returns (bool) {
    require(block.timestamp <= deadline, "ERC20Permit: Expired permit");

    bytes32 hashStruct = keccak256(
      abi.encode(
        TRANSFER_TYPEHASH,
        target,
        to,
        value,
        nonces[target]++,
        deadline
      )
    );

    require(
      verifyEIP712(target, hashStruct, v, r, s) ||
        verifyPersonalSign(target, hashStruct, v, r, s),
      "invalid EIP712 #2"
    );

    require(to != address(0) && to != address(this), "invalide to address #1");

    uint256 balance = balanceOf(target);
    require(balance >= value, "ERC20Permit: transfer amount exceeds balance");

    _transfer(target, to, value);

    return true;
  }

  function verifyEIP712(
    address target,
    bytes32 hashStruct,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) internal view returns (bool) {
    bytes32 hash = keccak256(
      abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), hashStruct)
    );

    address signer = ecrecover(hash, v, r, s);
    return (signer != address(0) && signer == target);
  }

  function verifyPersonalSign(
    address target,
    bytes32 hashStruct,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) internal pure returns (bool) {
    bytes32 hash = prefixed(hashStruct);
    address signer = ecrecover(hash, v, r, s);
    return (signer != address(0) && signer == target);
  }

  // Builds a prefixed hash to mimic the behavior of eth_sign.
  function prefixed(bytes32 hash) internal pure returns (bytes32) {
    return
      keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
  }

  function approveAndCall(
    address spender,
    uint256 value,
    bytes calldata data
  ) external returns (bool) {
    _approve(msg.sender, spender, value);

    return IApprovalReceiver(spender).onTokenApproval(msg.sender, value, data);
  }

  function transferAndCall(
    address to,
    uint256 value,
    bytes calldata data
  ) external returns (bool) {
    require(to != address(0) && to != address(this), "invalid to address #2");

    uint256 balance = balanceOf(msg.sender);
    require(balance >= value, "ERC20Permit: transfer amount exceeds balance");

    _transfer(msg.sender, to, value);

    return ITransferReceiver(to).onTokenTransfer(msg.sender, value, data);
  }
}
