// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "./interface/IMulticall.sol";

/// @title Multicall
/// @notice Enables calling multiple methods in a single call to the contract
abstract contract Multicall is IMulticall {
    /// @inheritdoc IMulticall
    function multicall(bytes[] calldata data) external virtual override returns (bytes[] memory) {
        bytes[] memory results = new bytes[](data.length);
        for (uint256 i; i < data.length;) {
            /// @custom:oz-upgrades-unsafe-allow-reachable delegatecall
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (success) {
                results[i] = result;
            } else {
                // Next 4 lines from
                // https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/master/contracts/utils/AddressUpgradeable.sol#L229
                if (result.length > 0) {
                    assembly {
                        let returndata_size := mload(result)
                        revert(add(32, result), returndata_size)
                    }
                } else {
                    revert FailedMulticall();
                }
            }

            unchecked {
                ++i;
            }
        }

        return results;
    }

    function extMulticall(CallData[] calldata calls) external virtual override returns (bytes[] memory) {
        return multicall2(calls);
    }

    /// @notice Aggregate calls, ensuring each returns success if required
    /// @param calls An array of CallData structs
    /// @return returnData An array of bytes
    function multicall2(CallData[] calldata calls) internal returns (bytes[] memory) {
        bytes[] memory results = new bytes[](calls.length);
        CallData calldata calli;
        for (uint256 i = 0; i < calls.length;) {
            calli = calls[i];
            (bool success, bytes memory result) = calli.target.call(calli.callData);
            if (success) {
                results[i] = result;
            } else {
                // Next 4 lines from
                // https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/master/contracts/utils/AddressUpgradeable.sol#L229
                if (result.length > 0) {
                    assembly {
                        let returndata_size := mload(result)
                        revert(add(32, result), returndata_size)
                    }
                } else {
                    revert FailedMulticall();
                }
            }

            unchecked {
                ++i;
            }
        }
        return results;
    }
}
