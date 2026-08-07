// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * \
 * Author: Terence An <terence@itos.fi>
 * Builds upon EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-253
 * by Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
 * /*****************************************************************************
 */
import {IDiamond} from "../Diamond/interfaces/IDiamond.sol";

interface ITimedDiamondCut is IDiamond {
    /// A new timed diamond cut has been initiated with these parameters and will take
    /// effect when confirmed after this emitted start time.
    event TimedDiamondCut(
        uint64 indexed startTime, uint256 assignmentId, FacetCut _diamondCut, address _init, bytes _calldata
    );

    /// Attempted to confirm a cut too early.
    error PrematureCutConfirmation(uint64 confirmTime);
    /// Emitted when the assignmentId doesn't map to any stored cut.
    error CutAssignmentNotFound(uint256 assignmentId);

    /// @notice Add/replace/remove one facet in a time-gated way. Optionally executes an
    /// initialization function with a delegate call.
    /// @param _cut The single FacetCut we want to install.
    /// @param _init The initialization contract for this facet we'll call into.
    /// @param _calldata The calldata called on the init function by delegate call.
    /// @return assignmentId The identifier to call with to confirm the cut once
    /// enough delay has passed.
    function timedDiamondCut(FacetCut calldata _cut, address _init, bytes calldata _calldata)
        external
        returns (uint256 assignmentId);

    /// @notice Accept a previously initiated timed diamond cut now that the delay
    /// has passed.
    function confirmCut(uint256 assignmentId) external;

    /// @notice Reject a previously initiated timed diamond cut.
    function vetoCut(uint256 assignmentId) external;

    /// @notice How much an initialized cut has to wait before it can be confirmed.
    function delay() external view returns (uint32);
}
