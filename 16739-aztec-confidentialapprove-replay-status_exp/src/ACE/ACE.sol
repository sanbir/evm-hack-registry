pragma solidity >=0.5.0 <0.6.0;

import "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import "../libs/NoteUtils.sol";

// Boundary-compatible adapter for the exact ZkAssetBase snapshot. The audit
// path only needs ACE's registry creation and note lookup; the other methods
// retain the signatures used by the real asset for compilation.
contract ACE {
    using NoteUtils for bytes;

    uint8 public latestEpoch;
    address public configuredOwner;

    function createNoteRegistry(address, uint256, bool, bool) external {}

    function setConfiguredOwner(address owner) external {
        configuredOwner = owner;
    }

    function getNote(address, bytes32) external view returns (uint8, uint40, uint40, address) {
        return (1, 0, 0, configuredOwner);
    }

    function validateProof(uint24, address, bytes calldata) external pure returns (bytes memory) {
        return new bytes(0);
    }

    function updateNoteRegistry(uint24, bytes calldata, address) external {}
}
