// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.8.0;

import {IPostDispatchHook} from "./interfaces/hooks/IPostDispatchHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


/// @title ProtocolFeeHook
/// @notice This contract implements a post-dispatch hook that requires a fee
/// to be paid after a message dispatch. The required fee is calculated based on
/// the current transaction gas price.
contract ProtocolFeeHook is IPostDispatchHook, Ownable{
    address public admin;

    uint256 public gasUsedPerTx = 97440; // Default gas used


    event DispatchFeePaid(uint256 requiredFee, uint256 actualFee);

    function hookType() external pure override returns (uint8) {
        return uint8(Types.PROTOCOL_FEE);
    }

   
    function supportsMetadata(
        bytes calldata
    ) external pure override returns (bool) {
        return true;
    }


    /// @notice Executes the post-dispatch logic.
    /// @dev Calculates the required fee and reverts if insufficient ETH is provided.
    /// @param metadata The metadata (unused).
    /// @param message The message (unused).
    function postDispatch(
        bytes calldata metadata,
        bytes calldata message
    ) external payable override {
        uint256 requiredFee = quoteDispatch(metadata, message);
        emit DispatchFeePaid(requiredFee, msg.value);

        require(msg.value >= requiredFee, "Insufficient fee paid");
    }

     /**
     * @notice Get quote for gas usage, not works in view txs.
      */

    function quoteDispatch(
        bytes calldata,
        bytes calldata
    ) public view override returns (uint256) {
        uint256 gasPrice = tx.gasprice;
        uint256 cost =  gasUsedPerTx * gasPrice;
        return cost;
    }

    /**
     * @notice Sets Gas used by update tx.
     * @param _gasUsedPerTx Gas Used.
     */
    function setGasUsedPerTx(uint256 _gasUsedPerTx) external onlyOwner {
        gasUsedPerTx = _gasUsedPerTx;
    }

    function withdrawFees(address feeRecipient) external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No balance to withdraw");

        (bool success, ) = payable(feeRecipient).call{value: balance}("");
        require(success, "Fee transfer failed");
    }

    receive() external payable {}

    fallback() external payable {}
}
