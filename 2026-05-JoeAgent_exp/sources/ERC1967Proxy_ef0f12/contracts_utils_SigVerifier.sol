// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/Strings.sol";

abstract contract SigVerifier {
    bytes26 constant ETH_SIGN_HEADER = bytes26("\x19Ethereum Signed Message:\n");

    function __digestFromMessage(bytes memory message) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(ETH_SIGN_HEADER, Strings.toString(message.length), message));
    }

    function __checkSignature(bytes32 digest, bytes32 r, bytes32 yParityAndS, address signer) internal pure {
        require(signer != address(0), "Signer cannot be empty address");
        bytes32 s = yParityAndS & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        uint8 v = uint8((uint256(yParityAndS) >> 255) + 27);
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "Invalid signature");

        require(signer == ecrecover(digest, v, r, s), "Invalid signature");
    }

    function __joinAddressList(address[] memory addrs) internal pure returns (string memory) {
        string memory result = "";

        for (uint256 i = 0; i < addrs.length; i++) {
            string memory addrStr = Strings.toHexString(addrs[i]);
            if (i == 0) {
                result = string(abi.encodePacked(addrStr, "\n"));
            } else {
                result = string(abi.encodePacked(result, addrStr, "\n"));
            }
        }

        return result;
    }
}
