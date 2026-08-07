// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2023 Itos Inc.
pragma solidity ^0.8.17;

import {IERC165} from "./interfaces/IERC165.sol";

// A contract can comply with ERC165 by simply inheriting this contract.
// Any other contracts it inherits from can indicate the supported interfaces
// by calling Auto165Lib.addSupport in their constructor and it'll automatically
// be incorporated into the supportsInterface call.
contract Auto165 is IERC165 {
    // The following is just an example.
    // Rarely does anyone need to indicate they support ERC165 by first supporting 165.
    // That's... useless...
    // constructor() {
    //     // This is how a parent contract automatically adds their support indication
    //     // to all child contracts.
    //     Auto165Lib.addSupport(type(IERC165).interfaceId);
    // }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external view virtual returns (bool) {
        return Auto165Lib.contains(interfaceId);
    }
}

library Auto165Lib {
    bytes32 public constant AUTO165_STORAGE_POSITION = keccak256("itos.auto165.diamond.storage");

    function interfaceStore() internal pure returns (mapping(bytes4 => bool) storage interfaces) {
        bytes32 position = AUTO165_STORAGE_POSITION;
        assembly {
            interfaces.slot := position
        }
    }

    /// Indicate this contract supports the given type({}).interfaceId
    function addSupport(bytes4 interfaceId) internal {
        mapping(bytes4 => bool) storage interfaces = interfaceStore();
        interfaces[interfaceId] = true;
    }

    /// Determine if the diamond storage of interfaces contains the given id.
    function contains(bytes4 interfaceId) internal view returns (bool) {
        mapping(bytes4 => bool) storage interfaces = interfaceStore();
        return interfaces[interfaceId];
    }
}
