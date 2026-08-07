// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.4;
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "../interfaces/Interfaces.sol";

/**
 * Smart contract library of mathematical functions operating with signed
 * 64.64-bit fixed point numbers.  Signed 64.64-bit fixed point number is
 * basically a simple fraction whose numerator is signed 128-bit integer and
 * denominator is 2^64.  As long as denominator is always the same,there is no
 * need to store it,thus in Solidity signed 64.64-bit fixed point numbers are
 * represented by int128 type holding only the numerator.
 */
library Validator {
    struct EIP712Domain {
        string name;
        string version;
        uint256 chainId;
        address verifyingContract;
    }

    function domainSperator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes("Validator")),
                    keccak256(bytes("1")),
                    block.chainid,
                    address(this)
                )
            );
    }

    function _validate(
        bytes32 hashData,
        bytes memory expectedSignature,
        address expectedSigner
    ) internal view returns (bool) {
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSperator(), hashData)
        );
        return
            SignatureChecker.isValidSignatureNow(
                expectedSigner,
                digest,
                expectedSignature
            );
    }

    function getUserTradeHash(
        IBufferRouter.TradeParams memory params,
        address user,
        IBufferRouter.SignInfo memory signInfo
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "UserTradeSignature(address user,uint256 totalFee,uint256 period,address targetContract,uint256 strike,uint256 slippage,bool allowPartialFill,string referralCode,uint256 traderNFTId,uint256 timestamp)"
                    ),
                    user,
                    params.totalFee,
                    params.period,
                    params.targetContract,
                    params.strike,
                    params.slippage,
                    params.allowPartialFill,
                    keccak256(bytes(params.referralCode)),
                    params.traderNFTId,
                    signInfo.timestamp
                )
            );
    }

    function getUserTradeHashWithSF(
        IBufferRouter.TradeParams memory params,
        address user,
        IBufferRouter.SignInfo memory signInfo
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "UserTradeSignatureWithSettlementFee(address user,uint256 totalFee,uint256 period,address targetContract,uint256 strike,uint256 slippage,bool allowPartialFill,string referralCode,uint256 traderNFTId,uint256 timestamp,uint256 settlementFee)"
                    ),
                    user,
                    params.totalFee,
                    params.period,
                    params.targetContract,
                    params.strike,
                    params.slippage,
                    params.allowPartialFill,
                    keccak256(bytes(params.referralCode)),
                    params.traderNFTId,
                    signInfo.timestamp,
                    params.settlementFee
                )
            );
    }

    function verifyUserTradeParams(
        IBufferRouter.TradeParams memory params,
        address user,
        address signer
    ) internal view returns (bool) {
        IBufferRouter.SignInfo memory signInfo = params.userSignInfo;
        bytes32 hashData;
        if (params.isLimitOrder) {
            hashData = getUserTradeHash(params, user, signInfo);
        } else {
            hashData = getUserTradeHashWithSF(params, user, signInfo);
        }
        return _validate(hashData, signInfo.signature, signer);
    }

    function verifyPublisher(
        string memory assetPair,
        uint256 timestamp,
        uint256 price,
        bytes memory signature,
        address signer
    ) internal view returns (bool) {
        bytes32 hashData = keccak256(
            abi.encodePacked(assetPair, timestamp, price)
        );
        bytes32 digest = ECDSA.toEthSignedMessageHash(hashData);
        return SignatureChecker.isValidSignatureNow(signer, digest, signature);
    }

    function verifyCloseAnytime(
        string memory assetPair,
        uint256 timestamp,
        uint256 optionId,
        bytes memory signature,
        address signer
    ) internal view returns (bool) {
        bytes32 hashData = keccak256(
            abi.encode(
                keccak256(
                    "CloseAnytimeSignature(string assetPair,uint256 timestamp,uint256 optionId)"
                ),
                keccak256(bytes(assetPair)),
                timestamp,
                optionId
            )
        );
        return _validate(hashData, signature, signer);
    }

    function verifySettlementFee(
        string memory assetPair,
        uint256 settlementFee,
        uint256 expiryTimestamp,
        bytes memory signature,
        address signer
    ) internal view returns (bool) {
        bytes32 hashData = keccak256(
            abi.encode(
                keccak256(
                    "SettlementFeeSignature(string assetPair,uint256 expiryTimestamp,uint256 settlementFee)"
                ),
                keccak256(bytes(assetPair)),
                expiryTimestamp,
                settlementFee
            )
        );
        return _validate(hashData, signature, signer);
    }

    function getMarketDirectionHashWithSF(
        IBufferRouter.CloseTradeParams memory params,
        IBufferRouter.QueuedTrade memory queuedTrade,
        IBufferRouter.SignInfo memory signInfo
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "MarketDirectionSignatureWithSettlementFee(address user,uint256 totalFee,uint256 period,address targetContract,uint256 strike,uint256 slippage,bool allowPartialFill,string referralCode,uint256 traderNFTId,bool isAbove,uint256 timestamp,uint256 settlementFee)"
                    ),
                    queuedTrade.user,
                    queuedTrade.totalFee,
                    queuedTrade.period,
                    queuedTrade.targetContract,
                    queuedTrade.strike,
                    queuedTrade.slippage,
                    queuedTrade.allowPartialFill,
                    keccak256(bytes(queuedTrade.referralCode)),
                    queuedTrade.traderNFTId,
                    params.isAbove,
                    signInfo.timestamp,
                    queuedTrade.settlementFee
                )
            );
    }

    function getMarketDirectionHash(
        IBufferRouter.CloseTradeParams memory params,
        IBufferRouter.QueuedTrade memory queuedTrade,
        IBufferRouter.SignInfo memory signInfo
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "MarketDirectionSignature(address user,uint256 totalFee,uint256 period,address targetContract,uint256 strike,uint256 slippage,bool allowPartialFill,string referralCode,uint256 traderNFTId,bool isAbove,uint256 timestamp)"
                    ),
                    queuedTrade.user,
                    queuedTrade.totalFee,
                    queuedTrade.period,
                    queuedTrade.targetContract,
                    queuedTrade.strike,
                    queuedTrade.slippage,
                    queuedTrade.allowPartialFill,
                    keccak256(bytes(queuedTrade.referralCode)),
                    queuedTrade.traderNFTId,
                    params.isAbove,
                    signInfo.timestamp
                )
            );
    }

    function verifyMarketDirection(
        IBufferRouter.CloseTradeParams memory params,
        IBufferRouter.QueuedTrade memory queuedTrade,
        address signer
    ) internal view returns (bool) {
        IBufferRouter.SignInfo memory signInfo = params.marketDirectionSignInfo;
        bytes32 hashData;
        if (queuedTrade.isLimitOrder) {
            hashData = getMarketDirectionHash(params, queuedTrade, signInfo);
        } else {
            hashData = getMarketDirectionHashWithSF(
                params,
                queuedTrade,
                signInfo
            );
        }
        return _validate(hashData, signInfo.signature, signer);
    }

    function verifyUserRegistration(
        address oneCT,
        address user,
        uint256 nonce,
        bytes memory signature
    ) internal view returns (bool) {
        bytes32 hashData = keccak256(
            abi.encode(
                keccak256(
                    "RegisterAccount(address oneCT,address user,uint256 nonce)"
                ),
                oneCT,
                user,
                nonce
            )
        );
        return _validate(hashData, signature, user);
    }

    function verifyUserDeregistration(
        address user,
        uint256 nonce,
        bytes memory signature
    ) internal view returns (bool) {
        bytes32 hashData = keccak256(
            abi.encode(
                keccak256("DeregisterAccount(address user,uint256 nonce)"),
                user,
                nonce
            )
        );
        return _validate(hashData, signature, user);
    }
}
