// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Nouns Builder — [H-1] when reservedUntilTokenId > 100 first founder loses
    1% NFT (Sherlock 2023-09-nounsbuilder-judging, finding #29423, reporter
    0x52).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: `_addFounders` seeds the scheduling cursor `baseTokenId`
    directly from `reservedUntilTokenId`, with no modulo:

        uint256 baseTokenId = reservedUntilTokenId;          // @> VULN

    Token ids only ever exist in [0, 99] (`_isForFounder` always reduces via
    `_tokenId % 100`), so if `reservedUntilTokenId > 100`, the FIRST scheduled
    slot (`tokenRecipient[reservedUntilTokenId]`, e.g. slot 200) is written at
    an id that NO real token id can ever land on — it is permanently
    unreachable. The founder ends up with one fewer usable allocation slot
    than they were promised (9 out of 10 scheduled slots, in this PoC), a
    concrete 1% loss of the total 100-token supply.
//////////////////////////////////////////////////////////////////////////*/

/// @notice Reduced Nouns Builder Token. Keeps the verbatim vulnerable
///         `baseTokenId = reservedUntilTokenId` seed in `addFounders` and the
///         verbatim `_tokenId % 100` reduction in `isForFounder`.
contract Token {
    struct Founder {
        address wallet;
        uint32 founderId;
        uint32 vestExpiry;
    }

    struct FounderParams {
        address wallet;
        uint256 percent; // founder's share, out of 100
        uint256 vestExpiry;
    }

    /// @dev ERC-721 token id => scheduled founder (verbatim field shape used
    ///      by the finding's own PoC: `(address wallet ,,) = tokenRecipient(id)`).
    mapping(uint256 => Founder) public tokenRecipient;

    /// @notice Verbatim reduction of Token._addFounders (Token.sol:L161 area).
    ///         `schedule` spaces a founder's allocations evenly across the
    ///         100-token mod space (100 / percent).
    function addFounders(FounderParams[] calldata founders, uint256 reservedUntilTokenId) external {
        for (uint256 i; i < founders.length; i++) {
            FounderParams calldata fp = founders[i];
            uint256 founderPct = fp.percent;
            uint256 schedule = 100 / founderPct;

            // @> VULN: seeded directly from reservedUntilTokenId, no % 100 —
            // if reservedUntilTokenId > 100 the first slot below is unreachable
            // FIX: `uint256 baseTokenId = 0;` or `uint256 baseTokenId = reservedUntilTokenId % 100;`
            uint256 baseTokenId = reservedUntilTokenId;

            for (uint256 j; j < founderPct; ++j) {
                baseTokenId = _getNextTokenId(baseTokenId);
                tokenRecipient[baseTokenId] =
                    Founder({wallet: fp.wallet, founderId: uint32(i), vestExpiry: uint32(fp.vestExpiry)});
                baseTokenId = (baseTokenId + schedule) % 100;
            }
        }
    }

    /// @notice Verbatim reduction of Token._getNextTokenId.
    function _getNextTokenId(uint256 _tokenId) internal view returns (uint256) {
        unchecked {
            while (tokenRecipient[_tokenId].wallet != address(0)) {
                _tokenId = (++_tokenId) % 100;
            }
            return _tokenId;
        }
    }

    /// @notice Verbatim reduction of Token._isForFounder. Every real token id
    ///         is reduced via `% 100` before lookup — so a slot scheduled at
    ///         a raw id >= 100 (like 200) can NEVER be reached from here.
    function isForFounder(uint256 _tokenId) external returns (bool) {
        uint256 baseTokenId = _tokenId % 100; // @> VULN: only ids < 100 are ever reachable

        if (tokenRecipient[baseTokenId].wallet == address(0)) {
            return false;
        } else if (block.timestamp < tokenRecipient[baseTokenId].vestExpiry) {
            return true; // real contract mints here; minting is elided (not needed for the harm)
        } else {
            delete tokenRecipient[baseTokenId];
            return false;
        }
    }
}

/// @notice Harness. Deploys the reduced Token, schedules a single founder with
///         a 10% allocation using a `reservedUntilTokenId` above 100 (200,
///         mirroring the finding's own example), then counts how many of the
///         100 real, reachable token ids actually resolve to the founder.
contract Exploit {
    address public constant FOUNDER = address(0xF0DE1);
    uint256 public constant RESERVED_UNTIL_TOKEN_ID = 200; // > 100 -> triggers the bug
    uint256 public constant FOUNDER_PCT = 10; // founder is promised 10% = 10 of 100 tokens

    Token public token; // nonce 1

    uint256 public reachableSlotsForFounder;
    bool public slot200SetForFounder;

    constructor() {
        token = new Token(); // CREATE nonce 1
    }

    function run() external {
        // Schedule a single founder with a 10% allocation using a
        // reservedUntilTokenId above 100 — this MUST run inside run() (not
        // the constructor) so the vulnerable line is captured in the trace.
        Token.FounderParams[] memory founders = new Token.FounderParams[](1);
        founders[0] = Token.FounderParams({wallet: FOUNDER, percent: FOUNDER_PCT, vestExpiry: type(uint32).max});
        token.addFounders(founders, RESERVED_UNTIL_TOKEN_ID);

        // The wasted slot IS written (the founder was promised it)...
        (address wallet200, , ) = token.tokenRecipient(RESERVED_UNTIL_TOKEN_ID);
        slot200SetForFounder = (wallet200 == FOUNDER);
        require(slot200SetForFounder, "setup: slot 200 should have been scheduled for the founder");

        // ...but no REAL token id (0-99) can ever reach it, since isForFounder
        // always reduces via `% 100`, and 200 % 100 == 0 while tokenRecipient[0]
        // was never actually written.
        (address wallet0, , ) = token.tokenRecipient(0);
        require(wallet0 == address(0), "harm setup failed: slot 0 should be empty");

        // Confirm via the REAL lookup path: token id 0 (== 200 % 100) does NOT
        // resolve to the founder, while token id 10 (a genuinely scheduled
        // slot) does.
        bool tokenZeroIsFounder = token.isForFounder(0);
        bool tokenTenIsFounder = token.isForFounder(10);
        require(!tokenZeroIsFounder, "harm not demonstrated: token 0 should not resolve to the founder");
        require(tokenTenIsFounder, "sanity: token 10 should resolve to the founder");

        // Count how many of the 100 REAL, reachable token ids actually belong
        // to the founder.
        uint256 count;
        for (uint256 id; id < 100; id++) {
            (address w, , ) = token.tokenRecipient(id);
            if (w == FOUNDER) count++;
        }
        reachableSlotsForFounder = count;

        // HARM: the founder was promised 10 of the 100 tokens (10%) but can
        // only ever actually receive 9 — a 1% loss of the total NFT supply.
        require(reachableSlotsForFounder == FOUNDER_PCT - 1, "harm not demonstrated: founder did not lose a slot");
    }
}
