pragma solidity ^0.8.20;

library SenderSlot {
    /// @notice used to store the current caller address when swapping tokens from the hook, since
    /// the caller address is lost when the hook is called from the core and while fitting the sender
    /// address in the hook data is possible, we need to decode from it, and the data is meant
    /// to be exclusively used by the hook to store callback arguments data for flash swap
    /// @dev keccak256(sender)-1 . sender as utf-8
    bytes32 constant internal SENDER_SLOT = 0x168E92CE035BA45E59A0314B0ED9A9E619B284AED8F6E5AB0A596EFD5C9F5CF8;

    function get() internal view returns (address) {
        address result;
        assembly ("memory-safe") {
            result := tload(SENDER_SLOT)
        }
        return result;
    }

    function set(address _sender) internal {
        assembly ("memory-safe") {
            tstore(SENDER_SLOT, _sender)
        }
    }

    function clear() internal {
        address zero = address(0);

        assembly ("memory-safe") {
            tstore(SENDER_SLOT, zero)
        }
    }
}
