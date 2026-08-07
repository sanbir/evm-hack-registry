// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * \
 * Author: Terence An <terence@itos.fi>
 * Builds upon EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-253
 * by Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
 * /*****************************************************************************
 */

import {ITimedDiamondCut} from "../interfaces/ITimedDiamondCut.sol";
import {IDiamond} from "../Diamond/interfaces/IDiamond.sol";
import {LibDiamond} from "../Diamond/libraries/LibDiamond.sol";

struct TimedCut {
    ITimedDiamondCut.FacetCut cut;
    address init;
    uint64 timestamp;
    bytes initCalldata;
}

/// The Diamond storage used for time gating facet cuts.
struct TimedCutStorage {
    mapping(uint256 => TimedCut) assignments;
    uint256 counter;
}

abstract contract TimedDiamondCutFacet is ITimedDiamondCut {
    bytes32 constant TIMED_DIAMOND_STORAGE_POSITION = keccak256("timed.diamond.cut.itos.storage");

    /// Get the diamond storage for our cuts.
    function timedCutStorage() internal pure returns (TimedCutStorage storage tcs) {
        bytes32 position = TIMED_DIAMOND_STORAGE_POSITION;
        assembly {
            tcs.slot := position
        }
    }

    /// @inheritdoc ITimedDiamondCut
    /// @dev Any child class of the time delayed diamond cut needs to specify a time delay.
    function delay() public view virtual returns (uint32);

    /// Validate that the caller has the correct permissions. Revert if incorrect.
    function validateCaller() internal view virtual;

    /// Validate that the caller has the correct veto permissions.
    function validateVeto() internal view virtual;

    /// @inheritdoc ITimedDiamondCut
    function timedDiamondCut(ITimedDiamondCut.FacetCut calldata _cut, address _init, bytes calldata _calldata)
        external
        override
        returns (uint256 assignmentId)
    {
        validateCaller();

        TimedCutStorage storage tcs = timedCutStorage();
        tcs.counter += 1; // Start at 1
        assignmentId = tcs.counter;

        TimedCut storage tCut = tcs.assignments[assignmentId];
        tCut.cut = _cut;
        tCut.init = _init;
        tCut.timestamp = uint64(block.timestamp);
        tCut.initCalldata = _calldata;

        emit ITimedDiamondCut.TimedDiamondCut(uint64(block.timestamp) + delay(), assignmentId, _cut, _init, _calldata);
    }

    /// @inheritdoc ITimedDiamondCut
    function confirmCut(uint256 assignmentId) external override {
        validateCaller();
        TimedCutStorage storage tcs = timedCutStorage();
        TimedCut storage tCut = tcs.assignments[assignmentId];

        if (tCut.timestamp == 0) {
            revert ITimedDiamondCut.CutAssignmentNotFound(assignmentId);
        }

        // We check the delay now in case it has changed since the install.
        uint64 confirmTime = tCut.timestamp + delay();
        if (uint64(block.timestamp) < confirmTime) {
            revert ITimedDiamondCut.PrematureCutConfirmation(confirmTime);
        }

        ITimedDiamondCut.FacetCut[] memory cuts = new ITimedDiamondCut.FacetCut[](1);
        cuts[0] = tCut.cut;

        LibDiamond.diamondCut(cuts, tCut.init, tCut.initCalldata);

        emit IDiamond.DiamondCut(cuts, tCut.init, tCut.initCalldata);

        // We no longer need it. Make sure no reinitialization happens.
        delete tcs.assignments[assignmentId];
    }

    /// @inheritdoc ITimedDiamondCut
    function vetoCut(uint256 assignmentId) external override {
        validateVeto();
        TimedCutStorage storage tcs = timedCutStorage();
        delete tcs.assignments[assignmentId];
    }
}
