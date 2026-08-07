// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

import {BaseAdminFacet} from "../Util/Admin.sol";
import {Timed} from "../Util/Timed.sol";
import {AdminLib} from "../Util/Admin.sol";

// A base class for admin facets that obey some opinionated time-gating.
abstract contract TimedAdminFacet is BaseAdminFacet {
    /// Return the useId to use in the Timed library.
    /// @param add True if we want to add rights. False if we want to remove them.
    function getRightsUseID(bool add) internal view virtual returns (uint256);

    /// The delay rights have to wait before being accepted.
    function getDelay() public view virtual returns (uint32);

    /// Submit rights in a Timed way to be accepted at a later time.
    /// @param add True if we want to add these rights. False if we want to remove them.
    function submitRights(address newAdmin, uint256 rights, bool add) external {
        AdminLib.validateOwner();
        Timed.memoryPrecommit(getRightsUseID(add), abi.encode(newAdmin, rights));
    }

    /// The owner can accept these rights changes.
    function acceptRights() external {
        AdminLib.validateOwner();
        bytes memory entry = Timed.fetchPrecommit(getRightsUseID(true), getDelay());
        (address admin, uint256 newRights) = abi.decode(entry, (address, uint256));
        AdminLib.register(admin, newRights);
    }

    /// Owner removes admin rights from an address in a time gated manner.
    function removeRights() external {
        AdminLib.validateOwner();
        bytes memory entry = Timed.fetchPrecommit(getRightsUseID(false), getDelay());
        (address admin, uint256 rights) = abi.decode(entry, (address, uint256));
        AdminLib.deregister(admin, rights);
    }

    /// The owner can veto rights additions.
    /// @param add Whether the veto is for an add to rights or a remove.
    function vetoRights(bool add) external {
        AdminLib.validateOwner();
        Timed.deleteEntry(getRightsUseID(add));
    }
}
