// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {packedFloat} from "../Types.sol";
import {Float128} from "../Float128.sol";
import {Ln} from "../Ln.sol";
import {MiniERC20} from "./MiniERC20.sol";

/// @title SpreadOptionVault — a minimal REAL consumer of Forte's Float128 / Ln library.
/// @notice A cash-settled "log-contract" options vault. Writers post `asset` collateral to
/// back holder payouts. A holder's position pays off `notional * ln(settlePrice - strike)`
/// (a log payoff, positive only when the option expires in the money, settlePrice > strike).
///
/// The vault TRUSTS `Ln.ln` to reject non-positive inputs — a mathematical library is
/// expected to fail explicitly on an invalid domain (this is exactly the guarantee AuditVault
/// finding 55705 / Code4rena Forte H-03 says the library must uphold). So the vault does NOT
/// itself guard `delta > 0` before taking the log. Because Forte's `Ln.ln` silently returns
/// `ln(|delta|)` for `delta <= 0` instead of reverting, an OUT-OF-THE-MONEY holder
/// (settlePrice < strike, a worthless option) is paid as if the option were in the money,
/// draining the writers' collateral.
contract SpreadOptionVault {
    using Float128 for packedFloat;

    MiniERC20 public immutable asset;
    uint256 public collateral; // writer-backed collateral held by the vault
    uint8 public constant PAYOUT_DECIMALS = 18;

    struct Position {
        address holder;
        packedFloat notional;
        packedFloat strike;
        bool settled;
    }

    Position[] public positions;

    constructor(MiniERC20 _asset) {
        asset = _asset;
    }

    /// @notice Writer posts collateral to back holder payouts.
    function fund(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        collateral += amount;
    }

    /// @notice Holder opens a log-contract position (premium accounting omitted for minimality).
    function open(address holder, packedFloat notional, packedFloat strike) external returns (uint256 id) {
        id = positions.length;
        positions.push(Position({holder: holder, notional: notional, strike: strike, settled: false}));
    }

    /// @notice Settle at the expiry price `settlePrice` (delivered by the market/oracle at expiry).
    /// Pays the holder `notional * ln(settlePrice - strike)` in `asset` units.
    function settle(uint256 id, packedFloat settlePrice) external returns (uint256 payout) {
        Position storage p = positions[id];
        require(!p.settled, "settled");
        p.settled = true;

        // Excess of settlement over strike. For an OTM expiry (settlePrice < strike) this is a
        // NEGATIVE Float128 and ln() SHOULD revert (log is defined only for x > 0), yielding a
        // zero payout. Instead Ln.ln returns ln(|delta|) and the holder is paid.
        packedFloat delta = settlePrice.sub(p.strike);
        packedFloat payoffPF = p.notional.mul(Ln.ln(delta));

        payout = _toTokenAmount(payoffPF);
        require(payout <= collateral, "insolvent");
        collateral -= payout;
        asset.transfer(p.holder, payout);
    }

    /// @notice Convert a (non-negative) Float128 payoff to `asset` token units at PAYOUT_DECIMALS.
    /// A correctly-signed negative payoff would trip the `m >= 0` guard here; the bug produces a
    /// POSITIVE payoff from a negative input, so it sails through.
    function _toTokenAmount(packedFloat pf) internal pure returns (uint256) {
        (int256 m, int256 e) = Float128.decode(pf);
        require(m >= 0, "negative payoff");
        int256 te = e + int256(uint256(PAYOUT_DECIMALS));
        if (te >= 0) return uint256(m) * (10 ** uint256(te));
        return uint256(m) / (10 ** uint256(-te));
    }
}
