// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Real OpenZeppelin IERC165 (utils/introspection/IERC165.sol). Vendored so the
// real Chainlink CCIPReceiver base can be compiled without the full OZ tree.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
