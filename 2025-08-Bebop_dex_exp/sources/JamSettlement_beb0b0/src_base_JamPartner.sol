// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../base/Errors.sol";
import "../libraries/JamOrder.sol";
import "../external-libs/SafeTransferLib.sol";

/// @title JamPartner
abstract contract JamPartner {

    uint16 internal constant HUNDRED_PERCENT = 10000;  // 100% in bps
    address internal immutable protocolFeeAddress;

    event NativeTransfer(address indexed receiver, uint256 amount);
    using SafeTransferLib for IERC20;

    constructor(address _protocolFeeAddress){
        protocolFeeAddress = _protocolFeeAddress;
    }

    /// @notice Distribute fees to the partner and protocol, fees are optional
    /// @param partnerInfo The partner info, packed with the partner address, partner fee and protocol fee
    /// @param token The token to distribute fees in
    /// @param amount Token amount in order to distribute fees from
    /// @return totalFeesSent The total amount of tokens sent as fees
    function distributeFees(uint256 partnerInfo, address token, uint256 amount) internal returns (uint256 totalFeesSent){
        (address partnerAddress, uint16 partnerFee, uint16 protocolFee) = unpackPartnerInfo(partnerInfo);
        if (partnerFee > 0) {
            totalFeesSent += sendPartnerFee(token, amount, partnerFee, partnerAddress);
        }
        if (protocolFee > 0) {
            totalFeesSent += sendPartnerFee(token, amount, protocolFee, protocolFeeAddress);
        }
        return totalFeesSent;
    }

    /// @notice Unpack the partner info
    /// @param partnerInfo Packed info: [ .... | address | uint16 | uint16 ]
    function unpackPartnerInfo(uint256 partnerInfo) private pure returns (address, uint16, uint16) {
        uint16 protocolFeeBps = uint16(partnerInfo & 0xFFFF);
        uint16 partnerFeeBps = uint16((partnerInfo >> 16) & 0xFFFF);
        address partnerAddress = address(uint160(partnerInfo >> 32));
        require(partnerFeeBps + protocolFeeBps < HUNDRED_PERCENT, InvalidFeePercentage());
        require(partnerFeeBps > 0 || (partnerFeeBps == 0 && partnerAddress == address(0)), InvalidPartnerAddress());
        return (partnerAddress, partnerFeeBps, protocolFeeBps);
    }

    /// @notice Send the partner fee
    /// @param token The token to send
    /// @param amount The amount to send
    /// @param fee The fee percentage
    /// @param receiver The receiver of the fee
    /// @return feeAmount The amount of fee sent
    function sendPartnerFee(address token, uint256 amount, uint16 fee, address receiver) private returns (uint256){
        uint256 feeAmount = amount * fee / HUNDRED_PERCENT;
        if (token == JamOrderLib.NATIVE_TOKEN) {
            (bool sent, ) = payable(receiver).call{value: feeAmount}("");
            require(sent, FailedToSendEth());
            emit NativeTransfer(receiver, feeAmount);
        } else {
            IERC20(token).safeTransfer(receiver, feeAmount);
        }
        return feeAmount;
    }

    /// @notice Get total fees in bps
    /// @param partnerInfo The partner info
    /// @return totalFeesBps The total fees in bps
    function getTotalFeesBps(uint256 partnerInfo) internal pure returns (uint16){
        uint16 protocolFeeBps = uint16(partnerInfo & 0xFFFF);
        uint16 partnerFeeBps = uint16((partnerInfo >> 16) & 0xFFFF);
        return protocolFeeBps + partnerFeeBps;
    }

    /// @notice Get arrays with fees amounts for each token
    /// @param amounts The amounts to calculate fees for
    /// @param minAmounts Minimum amounts that user signed for
    /// @param partnerInfo The partner info
    /// @return newAmounts The new amounts after fees
    /// @return protocolFees The protocol fees, if empty then no protocol fees
    /// @return partnerFees The partner fees, if empty then no partner fees
    /// @return partnerAddress The partner address, or zero address if no partner fees
    function getUpdatedAmountsAndFees(
        uint256[] calldata amounts, uint256[] calldata minAmounts, uint256 partnerInfo
    ) internal pure returns (uint256[] memory newAmounts, uint256[] memory protocolFees, uint256[] memory partnerFees, address) {
        (address partnerAddress, uint16 partnerFee, uint16 protocolFee) = unpackPartnerInfo(partnerInfo);
        uint tokensLength = amounts.length;
        require(minAmounts.length == tokensLength, InvalidFilledAmountsLength());
        newAmounts = new uint256[](tokensLength);
        if (protocolFee > 0) {
            protocolFees = new uint256[](tokensLength);
            for (uint256 i; i < tokensLength; ++i) {
                protocolFees[i] = amounts[i] * protocolFee / HUNDRED_PERCENT;
                newAmounts[i] = amounts[i] - protocolFees[i];
            }
        }
        if (partnerFee > 0) {
            partnerFees = new uint256[](tokensLength);
            for (uint256 i; i < tokensLength; ++i) {
                partnerFees[i] = amounts[i] * partnerFee / HUNDRED_PERCENT;
                newAmounts[i] = newAmounts[i] == 0 ? amounts[i] - partnerFees[i] : newAmounts[i] - partnerFees[i];
            }
        }
        for (uint256 i; i < tokensLength; ++i) {
            require(newAmounts[i] >= minAmounts[i], InvalidFilledAmounts(minAmounts[i], newAmounts[i]));
        }
        return (newAmounts, protocolFees, partnerFees, partnerAddress);
    }

}