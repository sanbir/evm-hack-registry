// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import { IERC173 } from "../ERC/interfaces/IERC173.sol";
import { Auto165Lib } from "../ERC/Auto165.sol";

/**
 * @title Administrative Library
 * @author Terence An
 * @notice This contains an administrative utility that uses diamond storage.
 * This is used to add and remove administrative privileges from addresses.
 * It also has validation functions for those privileges.
 * It adheres to ERC-173 which establishes an owernship standard.
 * @dev Administrative right assignments should be time-gated and veto-able for modern
 * contracts.
 *
 */

/// These are flags that can be joined so each is assigned its own hot bit.
/// @dev These flags get the very top bits so that user specific flags are given the lower bits.
library AdminFlags {
    uint256 public constant NULL = 0; // No clearance at all. Default value.
    uint256 public constant OWNER = 0x8000000000000000000000000000000000000000000000000000000000000000;
    uint256 public constant VETO = 0x4000000000000000000000000000000000000000000000000000000000000000;
}

struct AdminRegistry {
    // The owner actually does not have any rights except the ability to assign rights to users.
    // Of course it can assign rights to itself.
    // Thus it is probably desireable to qualify this ability, for example by time-gating it.
    address owner;
    // The owner can reassign ownership to a new address. This new address here must accept ownership
    // before it is actually transferred to avoid incorrect reassignemnts.
    address pendingOwner;
    // Rights are one hot encodings of permissions granted to users.
    // Each right should be a single bit in the uint256.
    mapping(address => uint256) rights;
}

/// Utility functions for checking, registering, and deregisterying administrative credentials
/// in a Diamond storage context. Most contracts that need this level of security sophistication
/// are probably large enough to required diamond storage.
library AdminLib {
    bytes32 constant ADMIN_STORAGE_POSITION = keccak256("v4.admin.diamond.storage");

    error NotOwner();
    error InsufficientCredentials(address caller, uint256 expectedRights, uint256 actualRights);
    error CannotReinitializeOwner(address existingOwner);
    error ImproperOwnershipAcceptance();

    event AdminAdded(address admin, uint256 newRight, uint256 existing);
    event AdminRemoved(address admin, uint256 removedRight, uint256 existing);

    function adminStore() internal pure returns (AdminRegistry storage adReg) {
        bytes32 position = ADMIN_STORAGE_POSITION;
        assembly {
            adReg.slot := position
        }
    }

    /* Getters */

    function getOwner() external view returns (address) {
        return adminStore().owner;
    }

    // @return lvl Will be cast to uint8 on return to external contracts.
    function getAdminRights(address addr) external view returns (uint256 rights) {
        return adminStore().rights[addr];
    }

    /* Validating Helpers */

    function validateOwner() internal view {
        if (msg.sender != adminStore().owner) {
            revert NotOwner();
        }
    }

    /// Revert if the msg.sender does not have the expected right.
    function validateRights(uint256 expected) internal view {
        AdminRegistry storage adReg = adminStore();
        uint256 actual = adReg.rights[msg.sender];
        if (actual & expected != expected) {
            revert InsufficientCredentials(msg.sender, expected, actual);
        }
    }

    /// Revert if the target does not have the expected right.
    function validateRights(address target, uint256 expected) internal view {
        AdminRegistry storage adReg = adminStore();
        uint256 actual = adReg.rights[target];
        if (actual & expected != expected) {
            revert InsufficientCredentials(msg.sender, expected, actual);
        }
    }

    /* Registry functions */

    /// Called when there is no owner so one can be set for the first time.
    function initOwner(address owner) internal {
        AdminRegistry storage adReg = adminStore();
        if (adReg.owner != address(0)) {
            revert CannotReinitializeOwner(adReg.owner);
        }
        adReg.owner = owner;
    }

    /// @notice Move ownership to another addres. The new owner is not immediately assigned
    /// and must confirm validity by accepting the ownership.
    /// @dev Remember to initialize the owner to a contract that can reassign on construction.
    function reassignOwner(address newOwner) internal {
        validateOwner();
        adminStore().pendingOwner = newOwner;
    }

    /// Once ownership has been reassigned to a new address, the new address must make a call to
    /// explicitly acceptance ownership. This avoids problems that can arise from incorrect reassignments.
    function acceptOwnership() internal {
        AdminRegistry storage adReg = adminStore();
        if (adReg.pendingOwner != msg.sender) {
            revert ImproperOwnershipAcceptance();
        }
        adReg.owner = msg.sender;
        adReg.pendingOwner = address(0);
    }

    /// Add a right to an address
    /// @dev When actually using, the importing function should add restrictions to this.
    function register(address admin, uint256 right) internal {
        AdminRegistry storage adReg = adminStore();
        uint256 existing = adReg.rights[admin];
        adReg.rights[admin] = existing | right;
        emit AdminAdded(admin, right, existing);
    }

    /// Remove a right from an address.
    /// @dev When using, the wrapper function should add restrictions.
    function deregister(address admin, uint256 right) internal {
        AdminRegistry storage adReg = adminStore();
        uint256 existing = adReg.rights[admin];
        adReg.rights[admin] = existing & (~right);
        emit AdminRemoved(admin, right, existing);
    }
}

/// Base class for an admin facet with external interactions with the AdminLib
contract BaseAdminFacet is IERC173 {
    constructor() {
        // ERC173 complies with 165.
        Auto165Lib.addSupport(type(IERC173).interfaceId);
    }

    function transferOwnership(address _newOwner) external override {
        AdminLib.reassignOwner(_newOwner);
    }

    function owner() external view override returns (address owner_) {
        owner_ = AdminLib.getOwner();
    }

    /// The pending owner can accept their ownership rights.
    function acceptOwnership() external {
        emit IERC173.OwnershipTransferred(AdminLib.getOwner(), msg.sender);
        AdminLib.acceptOwnership();
    }

    /// Fetch the admin level for an address.
    function adminRights(address addr) external view returns (uint256 rights) {
        return AdminLib.getAdminRights(addr);
    }
}
