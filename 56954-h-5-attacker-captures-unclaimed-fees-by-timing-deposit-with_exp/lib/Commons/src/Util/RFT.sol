// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright 2023 Itos Inc.
pragma solidity ^0.8.17;

import { Auto165Lib, IERC165 } from "../ERC/Auto165.sol";
import { IERC20 } from "../ERC/interfaces/IERC20.sol";
import { ContractLib } from "../Util/Contract.sol";
import { TransferHelper } from "../Util/TransferHelper.sol";
import { U256Ops } from "../Math/Ops.sol";

/* Interfaces to handle requests for tokens */
interface IRFTPayer {
    /**
     * @notice Called by other contracts requesting this contract for tokens.
     * @param tokens A list of tokens corresponding to each request.
     * @param requests A list of tokens amounts for each token.
     * Positive if requested, negative if paid to this contract.
     * @param data Additional information passed by the callee.
     * @return cbData bytes that the caller of settle can use
     */
    function tokenRequestCB(
        address[] calldata tokens,
        int256[] calldata requests,
        bytes calldata data
    ) external returns (bytes memory cbData);
}

/* Utilities for handling requests for tokens */

/// Contract that supports paying RFTs
abstract contract RFTPayer is IRFTPayer {
    constructor() {
        Auto165Lib.addSupport(type(IRFTPayer).interfaceId);
    }
}

library RFTLib {
    /* Internals */
    bytes32 constant RFT_STORAGE_POSITION = keccak256("itos.rft.20231109.diamond.storage");

    /// Revert when the tokens and the amount lengths don't match.
    error RFTLengthMismatch();
    /// Revert if after all CBs have resolved we don't have the expect change in balance.
    error InsufficientReceive(address token, int256 expected, int256 actual);
    /// Reentrancy attempted with non-reentry call.
    error ReentrancyLocked();

    enum ReentrancyStatus {
        Idle,
        Transacting,
        Locked
    }

    struct TotalTransact {
        ReentrancyStatus status;
        address[] tokens;
        mapping(address => int256) delta;
        mapping(address => uint256) startBalance;
    }

    /// Diamond storage for RFTLib if its used to settle balance changes
    function transactionStatus() private pure returns (TotalTransact storage transact) {
        bytes32 position = RFT_STORAGE_POSITION;
        assembly {
            transact.slot := position
        }
    }

    /* Utilities */

    /**
     * @notice Request & Send any tokens to change the balances as indicated. This is non-reentrant.
     * @notice Sends tokens regardless of what the payer is, but will do a RFT request if the payer
     * is a contract that supports IRFTPayer, otherwise it will transfer from.
     * @param payer Who the transaction is with. Can be a contract or a wallet. If it is a contract, it expects ERC165 support.
     * @param tokens The token list matching 1 to 1 to the balance changes we want.
     * @param balanceChanges The deltas we want in our balances for the given tokens. Positive means we receive tokens
     * as its a positive balance change from the caller's perspective. Negative means tokens will be sent.
     * @param data Any data to be sent to the payer if an RFT request is made.
     * @return actualDeltas The balance changes of the given tokens.
     */
    function settle(
        address payer,
        address[] memory tokens,
        int256[] memory balanceChanges,
        bytes memory data
    ) internal returns (int256[] memory actualDeltas, bytes memory cbData) {
        TotalTransact storage transact = transactionStatus();
        if (transact.status != ReentrancyStatus.Idle) {
            revert ReentrancyLocked();
        }

        transact.status = ReentrancyStatus.Locked;

        if (tokens.length != balanceChanges.length) {
            revert RFTLengthMismatch();
        }

        uint256[] memory startBalances = new uint256[](tokens.length);

        bool isRFTPayer = isSupported(payer);
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];
            int256 change = balanceChanges[i];
            startBalances[i] = IERC20(token).balanceOf(address(this));

            if (change < 0) {
                TransferHelper.safeTransfer(token, payer, uint256(-change));
            }
            // If we want tokens we transfer from when it is not an RFTPayer. Otherwise we wait to request at the end.
            if (change > 0 && !isRFTPayer) {
                TransferHelper.safeTransferFrom(token, payer, address(this), uint256(change));
            }
        }
        // If the payer is an RFTPayer, we make the request now.
        if (isRFTPayer) {
            cbData = IRFTPayer(payer).tokenRequestCB(tokens, balanceChanges, data);
        }

        actualDeltas = new int256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];

            // Validate our balances.
            uint256 finalBalance = IERC20(token).balanceOf(address(this));
            actualDeltas[i] = U256Ops.sub(finalBalance, startBalances[i]);
            if (actualDeltas[i] < balanceChanges[i]) {
                revert InsufficientReceive(token, balanceChanges[i], actualDeltas[i]);
            }
        }

        transact.status = ReentrancyStatus.Idle;
    }

    /**
     * @notice Request & Send any tokens to change the balances as indicated in a reentrant way.
     * @notice Sends tokens regardless of what the payer is, but will do a RFT request if the payer
     * is a contract that supports IRFTPayer, otherwise it will transfer from.
     * @notice This call can be nested multiple times as opposed to the normal settle function.
     * @param payer Who the transaction is with. Can be a contract or a wallet. If it is a contract, it expects ERC165 support.
     * @param tokens The token list matching 1 to 1 to the balance changes we want.
     * @param balanceChanges The deltas we want in our balances for the given tokens. Positive means we receive tokens
     * as its a positive balance change from the caller's perspective. Negative means tokens will be sent.
     * @param data Any data to be sent to the payer if an RFT request is made.
     * @dev This doesn't return the balance changes because in most cases it shouldn't be used.
     * It would report the aggregate balance change which if relied upon, can be fooled.
     */
    function reentrantSettle(
        address payer,
        address[] memory tokens,
        int256[] memory balanceChanges,
        bytes memory data
    ) internal returns (bytes memory cbData) {
        // We first setup the transaction we'll be handling.
        TotalTransact storage transact = transactionStatus();
        if (transact.status == ReentrancyStatus.Locked) {
            revert ReentrancyLocked();
        }
        bool outerContext = transact.status == ReentrancyStatus.Idle;

        if (outerContext) {
            transact.status = ReentrancyStatus.Transacting;
        }

        if (tokens.length != balanceChanges.length) {
            revert RFTLengthMismatch();
        }

        bool isRFTPayer = isSupported(payer);
        for (uint256 i = 0; i < tokens.length; ++i) {
            address token = tokens[i];

            // If this is the first time encountering this token, we have to track the starting balance.
            uint256 startBalance = transact.startBalance[token];
            if (startBalance == 0) {
                // The start balance can be 0 for either of two reasons. The caller actually has a balance of 0
                // in this token which is rare, or because we haven't encountered this token yet.
                // We can optimize by avoiding the first case by fudging the numbers a little.
                uint256 realStartBalance = IERC20(token).balanceOf(address(this));
                if (realStartBalance == 0) {
                    transact.startBalance[token] = 1;
                    transact.delta[token] = -1;
                    // Since the balance is 0 the request is obviously positive or else it'll fail on the transfer.
                    // So we can pretend our balance was originally 1 but we transfered that 1.
                    // The balance change is otherwise unchanged, and we still arrive at the correct final expected balance.
                    // The alternative to doing this optimization is another mapping that is a set of seen tokens.
                    // That would mean a cold storage write which is much more expensive than this conditional and
                    // hot write to transact.delta.
                } else {
                    transact.startBalance[token] = realStartBalance;
                }

                transact.tokens.push(token);
            }

            // Handle and track all balance changes.
            int256 change = balanceChanges[i];
            if (change < 0) {
                TransferHelper.safeTransfer(token, payer, uint256(-change));
            }
            // If we want tokens we transfer from when it is not an RFTPayer. Otherwise we wait to request at the end.
            if (change > 0 && !isRFTPayer) {
                TransferHelper.safeTransferFrom(token, payer, address(this), uint256(change));
            }

            // Handle bookkeeping.
            transact.delta[token] += change;
        }
        // If the payer is an RFTPayer, we make the request now.
        if (isRFTPayer) {
            cbData = IRFTPayer(payer).tokenRequestCB(tokens, balanceChanges, data);
        }

        // If we're done with all CBs, we reset the transact data and verify our new balances.
        if (outerContext) {
            uint256 lastIdx = transact.tokens.length - 1;
            for (uint256 i = 0; i <= lastIdx; ++i) {
                uint256 j = lastIdx - i;

                address token = transact.tokens[j];

                // Validate our balances.
                int256 expectedDelta = transact.delta[token];
                // Adding is cheaper so add in the common case.
                uint256 expectedBalance = U256Ops.add(transact.startBalance[token], expectedDelta);
                uint256 finalBalance = IERC20(token).balanceOf(address(this));
                if (finalBalance < expectedBalance) {
                    int256 actualDelta = U256Ops.sub(finalBalance, transact.startBalance[token]);
                    revert InsufficientReceive(token, expectedDelta, actualDelta);
                }

                // Cleanup
                transact.tokens.pop();
                delete transact.startBalance[token];
                delete transact.delta[token];
            }

            transact.status = ReentrancyStatus.Idle;
        }
    }

    /**
     * @notice Request tokens and indicate payments to a payer contract. This FORCES a request. We expect
     * a contract that is an IRFTPayer. This does not check for support the way transferOrRequest does.
     * @dev We simply INDICATE payments. The function caller is expect to actually do any payment transfers.
     * TODO: Cheapen gas by not asserting if its a contract first. Just attempt the request with a low level call.
     */
    function request(
        address payer,
        address[] memory tokens,
        int256[] memory amounts,
        bytes memory data
    ) internal returns (bytes memory cbData) {
        ContractLib.assertContract(payer);
        cbData = IRFTPayer(payer).tokenRequestCB(tokens, amounts, data);
    }

    /**
     * @notice Request tokens and indicate payments to a payer contract, or simply transfer if payer is not a contract.
     * @notice This is only to be used with contracts you trust, because there is no guarantee they pay you.
     * @notice Most of the time, you should just use settle.
     * @dev We simply INDICATE payments. The function caller is expect to actually do any payment transfers.
     * This call does not handle reentrancy, and that should be handled by the caller.
     * If you want reentrancy handled, then RFTLib must do any token sending, and you should use the settle function.
     * TODO: Cheapen gas by not checking isSupported. Just attempt the request with a low level call, and on failure
     * attempt a transfer from.
     */
    function requestOrTransfer(
        address payer,
        address[] memory tokens,
        int256[] memory amounts,
        bytes memory data
    ) internal returns (bytes memory cbData) {
        if (isSupported(payer)) {
            cbData = IRFTPayer(payer).tokenRequestCB(tokens, amounts, data);
        } else {
            for (uint256 i = 0; i < tokens.length; ++i) {
                if (amounts[i] > 0) {
                    TransferHelper.safeTransferFrom(tokens[i], payer, address(this), uint256(amounts[i]));
                }
            }
        }
    }

    /**
     * @notice Check if a contract supports RFTs through ERC165.
     * @return support True if RFTs are supported by the payer.
     */
    function isSupported(address payer) internal returns (bool support) {
        if (!ContractLib.isContract(payer)) return false;

        (bool success, bytes memory res) = payer.call(
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IRFTPayer).interfaceId)
        );

        if (!success) return false;

        return abi.decode(res, (bool));
    }
}
