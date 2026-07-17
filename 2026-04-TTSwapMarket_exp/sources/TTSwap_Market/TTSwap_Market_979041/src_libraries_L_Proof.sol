// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import {  sub, add, L_TTSwapUINT256Library} from "./L_TTSwapUINT256.sol";
import {I_TTSwap_Token} from "../interfaces/I_TTSwap_Token.sol";
import {S_ProofState, S_ProofKey} from "../interfaces/I_TTSwap_Market.sol";

/**
 * @title L_Proof Library
 * @notice Library for managing investment proofs and staking operations.
 * @dev Handles state updates for investment proofs (S_ProofState) and interactions with the TTS Token staking system.
 */
library L_Proof {
    using L_TTSwapUINT256Library for uint256;

    /**
     * @dev Updates the investment state of a proof after a new investment.
     * @param _self The storage pointer to the proof state being updated.
     * @param _currenctgood The address of the normal good being invested in.
     * @param _valuegood The address of the value good (if applicable).
     * @param _shares The shares to add (amount0: normal shares, amount1: value shares).
     * @param _state The value state to add (amount0: total value, amount1: total actual value).
     * @param _invest The normal good investment to add (amount0: virtual, amount1: actual).
     * @param _valueinvest The value good investment to add (amount0: virtual, amount1: actual).
     * @notice Updates the cumulative totals for shares, value, and investment quantities.
     * If this is the first investment (invest.amount1 == 0), it sets the `currentgood`.
     * If a value good is provided, it updates the `valuegood` address and amounts.
     */
    function updateInvest(
        S_ProofState storage _self,
        address _currenctgood,
        address _valuegood,
        uint256 _shares,
        uint256 _state,
        uint256 _invest,
        uint256 _valueinvest
    ) internal {
        if (_self.invest.amount1() == 0) _self.currentgood = _currenctgood;
        _self.shares = add(_self.shares, _shares);
        _self.state = add(_self.state, _state);
        _self.invest = add(_self.invest, _invest);
        if (_valuegood != address(0)) {
            if (_self.valuegood == address(0)) _self.valuegood = _valuegood;
            _self.valueinvest = add(_self.valueinvest, _valueinvest);
        }
    }

    /**
     * @dev Burns a portion of the proof during disinvestment.
     * @param _self The storage pointer to the proof state being updated.
     * @param _shares The shares to subtract (amount0: normal shares, amount1: value shares).
     * @param _state The value state to subtract (amount0: total value, amount1: total actual value).
     * @param _invest The normal good investment to subtract (amount0: virtual, amount1: actual).
     * @param _valueinvest The value good investment to subtract (amount0: virtual, amount1: actual).
     * @notice Reduces the cumulative totals. Used when a user withdraws liquidity.
     */
    function burnProof(
        S_ProofState storage _self,
        uint256 _shares,
        uint256 _state,
        uint256 _invest,
        uint256 _valueinvest
    ) internal {
        // If there's a value good, calculate and burn the corresponding amount of value investment
        if (_self.valuegood != address(0)) {
            _self.valueinvest = sub(_self.valueinvest, _valueinvest);
        }

        // Subtract the calculated investment from the total investment
        _self.invest = sub(_self.invest, _invest);
        // Reduce the total state by the burned value
        _self.state = sub(_self.state, _state);
        _self.shares = sub(_self.shares, _shares);
    }

    /**
     * @dev Stakes a certain amount of proof value to the TTS Token contract.
     * @param contractaddress The interface of the TTS Token contract.
     * @param to The address of the user staking the value.
     * @param proofvalue The amount of proof value to stake.
     * @return The net construction fee or value recorded by the token contract.
     * @notice Calls the external `stake` function on the TTS Token contract.
     */
    function stake(
        I_TTSwap_Token contractaddress,
        address to,
        uint128 proofvalue
    ) internal returns (uint128) {
        return contractaddress.stake(to, proofvalue);
    }

    /**
     * @dev Unstakes a certain amount of proof value from the TTS Token contract.
     * @param contractaddress The interface of the TTS Token contract.
     * @param from The address of the user unstaking.
     * @param divestvalue The amount of proof value to unstake.
     * @notice Calls the external `unstake` function on the TTS Token contract.
     */
    function unstake(
        I_TTSwap_Token contractaddress,
        address from,
        uint128 divestvalue
    ) internal {
        contractaddress.unstake(from, divestvalue);
    }
}

/**
 * @title L_ProofIdLibrary
 * @notice Library for calculating unique proof IDs.
 */
library L_ProofIdLibrary {
    /**
     * @dev Generates a unique ID for a proof key.
     * @param proofKey The proof key structure containing owner and good addresses.
     * @return poolId The Keccak-256 hash of the proof key.
     */
    function toId(S_ProofKey memory proofKey) internal pure returns (uint256 poolId) {
        assembly {
            poolId := keccak256(proofKey,0x60)
        }
    }
}
