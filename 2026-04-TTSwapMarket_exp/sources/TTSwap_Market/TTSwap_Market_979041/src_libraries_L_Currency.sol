// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {IAllowanceTransfer} from "../interfaces/IAllowanceTransfer.sol";
import {ISignatureTransfer} from "../interfaces/ISignatureTransfer.sol";
import {IERC20Permit} from "../interfaces/IERC20Permit.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IDAIPermit} from "../interfaces/IDAIPermit.sol";
import {L_Transient} from "./L_Transient.sol";
import {TTSwapError} from "./L_Error.sol";

address constant NATIVE = address(1);
// // mainnet
address constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
address constant _permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
// //testnet  
// address constant dai = 0xCaFBbAd55eb09efe7bec8408Cff9932Be7D9A7fA;
// address constant _permit2 = 0xa50eb0d081E986c280efF32dae089939Ea07bd22;

/// @title L_CurrencyLibrary
/// @notice This library allows for transferring and holding native tokens and ERC20 tokens.
/// @dev Handles various transfer methods including native ETH, standard ERC20 transferFrom, 
/// ERC20 Permit, and Permit2 (TransferFrom, Permit, PermitTransferFrom).
/// It abstracts away the complexity of different token standards and permit signatures.
library L_CurrencyLibrary {
    using L_CurrencyLibrary for address;

    struct S_Permit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct S_Permit2 {
        uint256 value;
        uint256 deadline;
        uint256 nonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    bytes constant defaultvalue = bytes("");

    /// @dev Structure to decode user-supplied transfer data.
    /// @param transfertype The type of transfer mechanism to use.
    /// 2: DAI-style Permit or EIP-2612 Permit
    /// 3: Permit2 TransferFrom (allowance already set)
    /// 4: Permit2 Permit + TransferFrom
    /// 5: Permit2 PermitTransferFrom (signature transfer)
    /// @param sigdata The encoded signature data (S_Permit or S_Permit2).
    struct S_transferData {
        uint8 transfertype;
        bytes sigdata;
    }

    /// @notice Thrown when an ETH transfer fails.
    error NativeETHTransferFailed();
    /// @notice Thrown when an ERC20 transfer fails (e.g. insufficient balance or allowance).
    error ERC20TransferFailed();
    /// @notice Thrown when an ERC20 Permit operation fails.
    error ERC20PermitFailed();
    /// @notice Thrown when an unsupported transfer type is provided.
    error UnsupportedTransferType();

    error ApproveFailed();

    function balanceof(
        address token,
        address _sender
    ) internal view returns (uint256 amount) {
        if (token.isNative()) {
            amount = address(_sender).balance;
        } else {
            amount = IERC20(token).balanceOf(_sender);
        }
    }

    /// @notice Transfers tokens from one address to another using various authorization methods.
    /// @dev Supports native ETH, standard ERC20, and various Permit schemes via `detail`.
    /// @param token The address of the token to transfer (or address(1) for native ETH).
    /// @param from The address to transfer tokens from.
    /// @param to The address to transfer tokens to.
    /// @param executor The address executing the transaction (usually msg.sender).
    /// @param amount The amount of tokens to transfer.
    /// @param detail Encoded `S_transferData` containing transfer type and signature data.
    /// @custom:security CRITICAL: If `token` is native ETH, `executor` MUST be `from`.
    /// @custom:security CRITICAL: If `detail` is provided, `transfertype` MUST be supported (2-5), otherwise it reverts.
    function transferFrom(
        address token,
        address from,
        address to,
        address executor,
        uint256 amount,
        bytes calldata detail
    ) internal {
        bool success;
        if (token.isNative()) {
            // Native ETH: value is tracked via L_Transient; executor must be the payer.
            if (executor != from) revert TTSwapError(39);
            L_Transient.decreaseValue(amount);
        } else if (detail.length == 0) {
            // Plain ERC20 transferFrom path (no permit).
            if (executor != from) revert  TTSwapError(39);
            transferFromInter(token, from, to, amount);
        } else {
            S_transferData memory _simplePermit = abi.decode(
                detail,
                (S_transferData)
            );
            if (_simplePermit.transfertype == 2) {
                // EIP-2612 or DAI-style permit: approve then transferFrom.
                S_Permit memory _permit = abi.decode(
                    _simplePermit.sigdata,
                    (S_Permit)
                );
                bytes memory inputdata = token == dai
                    ? abi.encodeCall(
                        IDAIPermit.permit,
                        (
                            from,
                            address(this),
                            IDAIPermit(token).nonces(from),
                            _permit.deadline,
                            true,
                            _permit.v,
                            _permit.r,
                            _permit.s
                        )
                    )
                    : abi.encodeCall(
                        IERC20Permit.permit,
                        (
                            from,
                            address(this),
                            _permit.value,
                            _permit.deadline,
                            _permit.v,
                            _permit.r,
                            _permit.s
                        )
                    );

                assembly {
                    success := call(
                        gas(),
                        token,
                        0,
                        add(inputdata, 32),
                        mload(inputdata),
                        0,
                        0
                    )
                }
                if (success) {
                    transferFromInter(token, from, to, amount);
                } else {
                    revert ERC20PermitFailed();
                }
            } else if (_simplePermit.transfertype == 3) {
                // Permit2 TransferFrom: allowance is pre-approved on Permit2.
                if (executor != from) revert  TTSwapError(39);
                IAllowanceTransfer(_permit2).transferFrom(
                    from,
                    to,
                    to_uint160(amount),
                    token
                );
            } else if (_simplePermit.transfertype == 4) {
                // Permit2 Permit + TransferFrom: set allowance on Permit2 then move tokens.
                S_Permit2 memory _permit = abi.decode(
                    _simplePermit.sigdata,
                    (S_Permit2)
                );
                IAllowanceTransfer(_permit2).permit(
                    from,
                    IAllowanceTransfer.PermitSingle({
                        details: IAllowanceTransfer.PermitDetails({
                            token: token,
                            amount: to_uint160(_permit.value),
                            // Use an unlimited expiration because it most
                            // closely mimics how a standard approval works.
                            expiration: type(uint48).max,
                            nonce: uint48(_permit.nonce)
                        }),
                        spender: address(this),
                        sigDeadline: _permit.deadline
                    }),
                    bytes.concat(_permit.r, _permit.s, bytes1(_permit.v))
                );

                IAllowanceTransfer(_permit2).transferFrom(
                    from,
                    to,
                    to_uint160(amount),
                    token
                );
            } else if (_simplePermit.transfertype == 5) {
                // Permit2 PermitTransferFrom: signature-based transfer without prior allowance.
                S_Permit2 memory _permit = abi.decode(
                    _simplePermit.sigdata,
                    (S_Permit2)
                );
                ISignatureTransfer(_permit2).permitTransferFrom(
                    ISignatureTransfer.PermitTransferFrom({
                        permitted: ISignatureTransfer.TokenPermissions({
                            token: token,
                            amount: _permit.value
                        }),
                        nonce: _permit.nonce,
                        deadline: _permit.deadline
                    }),
                    ISignatureTransfer.SignatureTransferDetails({
                        to: to,
                        requestedAmount: amount
                    }),
                    from,
                    bytes.concat(_permit.r, _permit.s, bytes1(_permit.v))
                );
            } else {
                revert TTSwapError(42);
            }
        }
    }

    function transferFrom(
        address token,
        address from,
        address executor,
        uint256 amount,
        bytes calldata trandata
    ) internal {
        address to = address(this);
        transferFrom(token, from, to, executor, uint128(amount), trandata);
    }

    function transferFromInter(
        address currency,
        address from,
        address to,
        uint256 amount
    ) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(
                freeMemoryPointer,
                0x23b872dd00000000000000000000000000000000000000000000000000000000
            )
            mstore(
                add(freeMemoryPointer, 4),
                and(from, 0xffffffffffffffffffffffffffffffffffffffff)
            ) // Append and mask the "from" argument.
            mstore(
                add(freeMemoryPointer, 36),
                and(to, 0xffffffffffffffffffffffffffffffffffffffff)
            ) // Append and mask the "to" argument.
            mstore(add(freeMemoryPointer, 68), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

            // We use 100 because the length of our calldata totals up like so: 4 + 32 * 3.
            // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
            success := call(gas(), currency, 0, freeMemoryPointer, 100, 0, 32)

            // Set success to whether the call reverted, if not we check it either
            // returned exactly 1 (can't just be non-zero data), or had no return data and token has code.
            if and(
                iszero(and(eq(mload(0), 1), gt(returndatasize(), 31))),
                success
            ) {
                success := iszero(
                    or(iszero(extcodesize(currency)), returndatasize())
                )
            }
        }

        if (!success) revert ERC20TransferFailed();
    }

    function safeTransfer(
        address currency,
        address to,
        uint256 amount
    ) internal {
        // implementation from
        // https://github.com/transmissions11/solmate/blob/e8f96f25d48fe702117ce76c79228ca4f20206cb/src/utils/SafeTransferLib.sol

        bool success;
        if (currency.isNative()) {
            assembly {
                // Transfer the ETH and store if it succeeded or not.
                success := call(gas(), to, amount, 0, 0, 0, 0)
            }
            if (!success) revert NativeETHTransferFailed();
        } else {
            /// @solidity memory-safe-assembly
            assembly {
                // Get a pointer to some free memory.
                let freeMemoryPointer := mload(0x40)

                // Write the abi-encoded calldata into memory, beginning with the function selector.
                mstore(
                    freeMemoryPointer,
                    0xa9059cbb00000000000000000000000000000000000000000000000000000000
                )
                mstore(
                    add(freeMemoryPointer, 4),
                    and(to, 0xffffffffffffffffffffffffffffffffffffffff)
                ) // Append and mask the "to" argument.
                mstore(add(freeMemoryPointer, 36), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

                // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                success := call(
                    gas(),
                    currency,
                    0,
                    freeMemoryPointer,
                    68,
                    0,
                    32
                )

                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data and token has code.
                if and(
                    iszero(and(eq(mload(0), 1), gt(returndatasize(), 31))),
                    success
                ) {
                    success := iszero(
                        or(iszero(extcodesize(currency)), returndatasize())
                    )
                }
            }

            if (!success) revert ERC20TransferFailed();
        }
    }

    function isNative(address currency) internal pure returns (bool) {
        return currency == address(1);
    }

    function to_uint160(uint256 amount) internal pure returns (uint160) {
        if (amount != uint160(amount)) revert TTSwapError(46);
return uint160(amount);
    }

    function to_uint256(address amount) internal pure returns (uint256 a) {
        return uint256(uint160(amount));
    }
}
