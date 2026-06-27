// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

// Contracts
import { AugustusFees } from "../fees/AugustusFees.sol";

// Interfaces
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

// Libraries
import { SafeCastLib } from "@solady/utils/SafeCastLib.sol";

/// @title BalancerV2Utils
/// @notice A contract containing common utilities for BalancerV2 swaps
abstract contract BalancerV2Utils is AugustusFees {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeCastLib for int256;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev BalancerV2 vault address
    address payable public immutable BALANCER_VAULT; // solhint-disable-line var-name-mixedcase

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address payable _balancerVault) {
        BALANCER_VAULT = _balancerVault;
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Decode srcToken, destToken, fromAmount from executorData
    /// and  beneficiary and approve flag from beneficiaryAndApproveFlag
    function _decodeBalancerV2Params(
        uint256 beneficiaryAndApproveFlag,
        bytes calldata executorData
    )
        internal
        pure
        returns (
            IERC20 srcToken,
            IERC20 destToken,
            address payable beneficiary,
            uint256 approve,
            uint256 fromAmount,
            uint256 toAmount
        )
    {
        int256 _toAmount;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // Parse beneficiaryAndApproveFlag
            beneficiary := and(beneficiaryAndApproveFlag, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            approve := shr(255, beneficiaryAndApproveFlag)

            // Skip selector
            let callDataWithoutSelector := add(4, executorData.offset)
            // Load assetOffset from executorData
            let assetsOffset := calldataload(add(callDataWithoutSelector, 64))
            // Load assetCount at assetOffset
            let assetsCount := calldataload(add(callDataWithoutSelector, assetsOffset))
            // Get swapExactAmountIn type from first 32 bytes of executorData
            let swapType := calldataload(callDataWithoutSelector)
            // Set fromAmount, srcToken, toAmount and destToken based on swapType
            switch eq(swapType, 1)
            case 1 {
                // Load srcToken as the last asset in executorData.assets
                srcToken := calldataload(add(callDataWithoutSelector, add(assetsOffset, mul(assetsCount, 32))))
                // Load destToken as the first asset in executorData.assets
                destToken := calldataload(add(callDataWithoutSelector, add(assetsOffset, 32)))
                // Load fromAmount from executorData at limits[assetCount-1]
                fromAmount := calldataload(add(callDataWithoutSelector, sub(executorData.length, 36)))
                // Load toAmount from executorData at limits[0]
                _toAmount :=
                    calldataload(add(callDataWithoutSelector, sub(sub(executorData.length, 4), mul(assetsCount, 32))))
            }
            default {
                // Load srcToken as the first asset in executorData.assets
                srcToken := calldataload(add(callDataWithoutSelector, add(assetsOffset, 32)))
                // Load destToken as the last asset in executorData.assets
                destToken := calldataload(add(callDataWithoutSelector, add(assetsOffset, mul(assetsCount, 32))))
                // Load fromAmount from executorData at limits[0]
                fromAmount :=
                    calldataload(add(callDataWithoutSelector, sub(sub(executorData.length, 4), mul(assetsCount, 32))))
                // Load toAmount from executorData at limits[assetCount-1]
                _toAmount := calldataload(add(callDataWithoutSelector, sub(executorData.length, 36)))
            }
            // Balancer users 0x0 as ETH address so we need to convert it
            if eq(srcToken, 0) { srcToken := 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE }
            if eq(destToken, 0) { destToken := 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE }
        }
        return (srcToken, destToken, beneficiary, approve, fromAmount, (-_toAmount).toUint256());
    }

    /// @dev Call balancerVault with data
    function _callBalancerV2(bytes calldata executorData) internal {
        address payable targetAddress = BALANCER_VAULT;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            // Load free memory pointer
            let ptr := mload(64)
            // Copy the executorData to memory
            calldatacopy(ptr, executorData.offset, executorData.length)
            // Execute the call on balancerVault
            if iszero(call(gas(), targetAddress, callvalue(), ptr, executorData.length, 0, 0)) {
                returndatacopy(ptr, 0, returndatasize()) // copy the revert data to memory
                revert(ptr, returndatasize()) // revert with the revert data
            }
        }
    }
}
