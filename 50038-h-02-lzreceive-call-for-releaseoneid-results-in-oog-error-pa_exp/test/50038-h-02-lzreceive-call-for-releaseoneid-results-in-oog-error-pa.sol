// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  NFTMirror — [H-02] lzReceive() for releaseOnEid() results in OOG
    (Pashov Audit Group, NFTMirror-security-review 2024-12-30; #50038)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: NFTShadow.getSendOptions underestimates gas for lzReceive on the
    destination. Per-token budget is only 20_000 (plus 80_000 base), but minting a
    shadow NFT costs ~46_700+ gas. Destination OOGs; message stored for retry.
    Vulnerable getSendOptions formula preserved @>. Sample+extrapolate pattern. */

contract NFTShadow {
    uint128 private constant _BASE_OWNERSHIP_UPDATE_COST = 80_000;
    uint128 private constant _INCREMENTAL_OWNERSHIP_UPDATE_COST = 20_000;

    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bool) public exists;
    address public beacon;

    // Tuned so one mint burns just over the 100k budget (base+1*incremental),
    // without exploding in-browser opcode counts (sample+extrapolate style).
    uint256 public mintWorkUnits = 700;

    uint256 public lastMintGas; // measured per unlockTokens call

    constructor(address _beacon) {
        beacon = _beacon;
    }

    /// @dev Vulnerable gas-option calculator — VERBATIM formula from the report.
    function getSendOptions(uint256[] calldata tokenIds) public view returns (uint128 totalGasRequired) {
        // Keep as view (not pure) so the playground recorder attributes PCs to this contract.
        // @> VULN: incremental 20k/token is far below real mint/transfer cost (~46.7k+)
        totalGasRequired = _BASE_OWNERSHIP_UPDATE_COST
            + (_INCREMENTAL_OWNERSHIP_UPDATE_COST * uint128(tokenIds.length)); // @> VULN
        // FIX: raise base/incremental; allow user override of lzReceive gas.
        // silence unused state read so compiler keeps view linkage
        if (mintWorkUnits == type(uint256).max) totalGasRequired = 0;
    }

    /// @dev Destination-side unlock/mint that under-budgeted lzReceive must run.
    function unlockTokens(uint256[] calldata tokenIds, address recipient) external {
        require(msg.sender == beacon, "beacon");
        uint256 g0 = gasleft();
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _mintWithWork(recipient, tokenIds[i]);
        }
        lastMintGas = g0 - gasleft();
    }

    function _mintWithWork(address to, uint256 tokenId) internal {
        uint256 acc;
        uint256 w = mintWorkUnits;
        for (uint256 i = 0; i < w; i++) {
            acc ^= uint256(keccak256(abi.encodePacked(i, tokenId)));
        }
        // keep side effect so optimizer cannot drop the loop
        if (acc == 1) {
            mintWorkUnits = w;
        }
        exists[tokenId] = true;
        ownerOf[tokenId] = to;
    }
}

/// @dev Minimal beacon / LZ endpoint stand-in.
contract Beacon {
    NFTShadow public shadow;
    mapping(uint32 => mapping(bytes32 => mapping(uint64 => bytes32))) public payloadHashes;

    function setShadow(NFTShadow s) external {
        shadow = s;
    }

    /// @dev Direct full-gas path (no stipend) — used to measure real cost.
    function unlockFull(uint256[] calldata tokenIds, address recipient) external {
        shadow.unlockTokens(tokenIds, recipient);
    }

    /// @dev Models DVN calling lzReceive with the options-derived gas stipend.
    function lzReceive(uint128 gasLimit, uint256[] calldata tokenIds, address recipient)
        external
        returns (bool ok)
    {
        // Forward only `gasLimit` gas to the destination handler (EIP-150 applies).
        (bool success,) = address(shadow).call{gas: gasLimit}(
            abi.encodeWithSelector(NFTShadow.unlockTokens.selector, tokenIds, recipient)
        );
        if (!success) {
            // Stored for retry (finding: payloadHashes != 0).
            payloadHashes[1][bytes32(uint256(uint160(msg.sender)))][0] =
                keccak256(abi.encode(tokenIds, recipient));
            return false;
        }
        return true;
    }
}

contract Exploit {
    Beacon public beacon; // CREATE nonce 1
    NFTShadow public shadow; // CREATE nonce 2 — vulnerable

    uint128 public budget;
    uint256 public gasUsedSample;
    bool public oogStored;

    constructor() {
        beacon = new Beacon();
        shadow = new NFTShadow(address(beacon));
        beacon.setShadow(shadow);
    }

    function run() external {
        // 1. Vulnerable budget for 1 token: 80_000 + 20_000 * 1 = 100_000
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 8903;
        budget = shadow.getSendOptions(tokenIds);
        require(budget == 100_000, "budget formula");

        // 2. Sample with full gas — measure real destination cost for 1 token.
        uint256[] memory sampleIds = new uint256[](1);
        sampleIds[0] = 1;
        beacon.unlockFull(sampleIds, address(0xBEEF));
        require(shadow.exists(1), "minted under full gas");
        gasUsedSample = shadow.lastMintGas();
        require(gasUsedSample > 0, "measured");

        // Sample must exceed the protocol budget (underfunded).
        require(gasUsedSample > uint256(budget), "sample exceeds budget");
        // Incremental alone is underfunded (finding: mint ~46.7k > 20k).
        require(gasUsedSample > 20_000, "incremental underfunded");

        // 3. Dispatch with vulnerable budget → OOG/fail → stored for retry.
        uint256[] memory attackIds = new uint256[](1);
        attackIds[0] = 8903;
        bool okBudgeted = beacon.lzReceive(budget, attackIds, address(0xCAFE));
        require(!okBudgeted, "budgeted call should fail");
        require(!shadow.exists(8903), "must not mint under budget");

        bytes32 ph = beacon.payloadHashes(1, bytes32(uint256(uint160(address(this)))), 0);
        require(ph != bytes32(0), "message stored for retry");
        oogStored = true;

        // Harm: releaseOnEid's lzReceive OOGs under computed options; always needs retry.
        // Extrapolation: cost ≈ N * perToken; budget = 80k + 20k*N; perToken > 20k ⇒ all N underfunded.
    }
}
