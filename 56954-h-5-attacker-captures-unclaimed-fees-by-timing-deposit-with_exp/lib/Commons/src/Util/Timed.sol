// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.13;

/**
 * @title Timed Storage Update library
 * @author Terence An
 * @notice A library for modifying storage in a time gated way.
 * There are lots of ways to manage storage, but for security purposes
 * it's recommended that you consolidate parameterizations into one file,
 * use just the pre-commit function to initiate changes, and write usage
 * specific commit functions that do the required validation.
 * For an example using this with Diamond storage, see the Params.sol file
 * in Itos 2sAMM repo.
 *
 */

struct TimedEntry {
    // 64 bits is more than enough. If necessary a timeout can be introduced to shorten these bits further
    uint64 timestamp;
    // Who pre-committed. This entry is not always used, but we get it for free since timestamp is 64 bits.
    address submitter;
    // The bytes to be decoded by the specific use case.
    bytes entry;
}

struct PreCommits {
    // A mapping from the usage id to its pre-committed entry.
    mapping(uint256 => TimedEntry) entries;
}

/**
 * @notice Modifications are precommitted with a bytes entry and a usage id.
 * The usage id is what specific parts of the contract use to fetch the releveant
 * modifications for themselves. They decode the bytes entry with their expected type
 * and use the values as they see fit.
 * For each usage id, there can only be one precommit to competing commits
 *
 */
library Timed {
    /// Diamond storage address if you choose to use use it.
    bytes32 constant TIMED_STORAGE_POSITION = keccak256("v4.timed.diamond.storage");

    /// Thrown when a useIds update is attempted before the required time has passed.
    error PrematureParamUpdate(uint256 useId, uint64 expectedTime, uint64 actualTime);
    error NoPrecommitFound(uint256 useId);
    /// Only one precommit can exist for a useId at a time. Either Veto or Accept the existing precommit first.
    error ExistingPrecommitFound(uint256 useId);

    event PreCommit(uint256 indexed useId, address indexed submitter, bytes entry);

    /// Use in an external contract function to submit time gated changes.
    function precommit(PreCommits storage s, uint256 useId, bytes calldata _entry) internal {
        TimedEntry storage entry = s.entries[useId];
        if (entry.timestamp != 0)
            revert ExistingPrecommitFound(useId);
        entry.timestamp = uint64(block.timestamp);
        entry.submitter = msg.sender;
        entry.entry = _entry;

        emit PreCommit(useId, msg.sender, _entry);
    }

    /// To be used by usage functions that accepted the time gated changes.
    function fetchAndDelete(PreCommits storage s, uint256 useId) internal returns (TimedEntry memory e) {
        e = s.entries[useId];
        delete s.entries[useId];
    }

    /// Used to view pending changes.
    function fetch(PreCommits storage s, uint256 useId) internal view returns (TimedEntry memory e) {
        e = s.entries[useId];
    }

    /// Save a little gas when you just want to delete.
    function deleteEntry(PreCommits storage s, uint256 useId) internal {
        delete s.entries[useId];
    }

    /// Convenience function for fetching from diamond storage if you choose to use it.
    function timedStore() internal pure returns (PreCommits storage pcs) {
        bytes32 position = TIMED_STORAGE_POSITION;
        assembly {
            pcs.slot := position
        }
    }

    /*
      Diamond storage using variants of the above
      A good compiler should make these cheap.
     */

    function precommit(uint256 useId, bytes calldata entry) internal {
        precommit(timedStore(), useId, entry);
    }

    // precommit but from memory bytes. Using calldata saves a copy when the input is calldata,
    // but in some cases we build an in-memory bytes array.
    function memoryPrecommit(uint256 useId, bytes memory _entry) internal {
        PreCommits storage s = timedStore();
        TimedEntry storage entry = s.entries[useId];
        if (entry.timestamp != 0)
            revert ExistingPrecommitFound(useId);
        entry.timestamp = uint64(block.timestamp);
        entry.submitter = msg.sender;
        entry.entry = _entry;

        emit PreCommit(useId, msg.sender, _entry);
    }

    function fetchAndDelete(uint256 useId) internal returns (TimedEntry memory e) {
        return fetchAndDelete(timedStore(), useId);
    }

    function fetch(uint256 useId) internal view returns (TimedEntry memory e) {
        return fetch(timedStore(), useId);
    }

    function deleteEntry(uint256 useId) internal {
        deleteEntry(timedStore(), useId);
    }

    /* Convenience functions for building on top of */

    // A helper for the most common usage pattern.
    // Fetch the precommit data and error if it doesn't exist or the fetch is premature
    // according to the passed in delay. Delete the entry from the bookkeeping if returned.
    function fetchPrecommit(uint256 useId, uint32 delay) internal returns (bytes memory e) {
        TimedEntry memory tde = fetchAndDelete(useId); // delete will undo if reverted.
        if (tde.timestamp == 0)
            revert NoPrecommitFound(useId);

        uint64 actualTime = uint64(block.timestamp);
        uint64 expectedTime = tde.timestamp + delay;
        if (actualTime < expectedTime)
            revert PrematureParamUpdate(useId, expectedTime, actualTime);

        e = tde.entry;
    }
}

/// A Base class for users to build a facet upon.
contract BaseTimedFacet {
    /// Fetch any pending changes
    function fetch(uint256 useId) public view returns (TimedEntry memory e) {
        return Timed.fetch(Timed.timedStore(), useId);
    }
}
