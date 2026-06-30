// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import "../base/Errors.sol";
import "../libraries/JamOrder.sol";
import "../libraries/JamHooks.sol";
import "../JamBalanceManager.sol";
import "lib/openzeppelin-contracts/contracts/interfaces/IERC1271.sol";
import "lib/openzeppelin-contracts/contracts/interfaces/IERC5267.sol";

/// @title JamValidation
/// @notice Functions which handles the signing and validation of Jam orders
abstract contract JamValidation is IERC5267 {
    mapping(address => mapping(uint256 => uint256)) private standardNonces;
    mapping(address => mapping(uint256 => uint256)) private limitOrdersNonces;
    uint256 private constant INF_EXPIRY = 9999999999; // expiry for limit orders

    string public constant DOMAIN_NAME = "JamSettlement";
    string public constant DOMAIN_VERSION = "2";
    bytes32 private constant UPPER_BIT_MASK = (0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
    bytes4 private constant EIP1271_MAGICVALUE = bytes4(keccak256("isValidSignature(bytes32,bytes)"));
    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(abi.encodePacked(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    ));

    IJamBalanceManager public immutable balanceManager;
    IPermit2 private immutable PERMIT2;
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    using JamOrderLib for JamOrder;

    constructor(address _permit2){
        balanceManager = new JamBalanceManager(address(this), _permit2);
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(DOMAIN_NAME)), keccak256(bytes(DOMAIN_VERSION)), block.chainid, address(this))
        );
        PERMIT2 = IPermit2(_permit2);
    }

    /// @notice The domain separator used in the order validation signature
    /// @return The domain separator used in encoding of order signature
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID
            ? _CACHED_DOMAIN_SEPARATOR
            : keccak256(
                abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256(bytes(DOMAIN_NAME)), keccak256(bytes(DOMAIN_VERSION)), block.chainid, address(this))
            );
    }

    /// @notice ERC5267 implementation for requesting the EIP712 domain values
    function eip712Domain() public view returns (
        bytes1 fields, string memory name, string memory version, uint256 chainId,
        address verifyingContract, bytes32 salt, uint256[] memory extensions
    ){
        return (hex"0f", DOMAIN_NAME, DOMAIN_VERSION, block.chainid, address(this), bytes32(0), new uint256[](0));
    }

    /// @notice Validate the order signature
    /// @param validationAddress The address to validate the signature against
    /// @param hash The hash of the order
    /// @param signature The signature to validate
    function validateSignature(address validationAddress, bytes32 hash, bytes calldata signature) public view {
        bytes32 r;
        bytes32 s;
        uint8 v;
        if (validationAddress.code.length == 0) {
            if (signature.length == 65) {
                (r, s) = abi.decode(signature, (bytes32, bytes32));
                v = uint8(signature[64]);
            } else if (signature.length == 64) {
                // EIP-2098
                bytes32 vs;
                (r, vs) = abi.decode(signature, (bytes32, bytes32));
                s = vs & UPPER_BIT_MASK;
                v = uint8(uint256(vs >> 255)) + 27;
            } else {
                revert InvalidSignatureLength();
            }
            address signer = ecrecover(hash, v, r, s);
            if (signer == address(0)) revert InvalidSignature();
            if (signer != validationAddress) revert InvalidSigner();
        } else {
            bytes4 magicValue = IERC1271(validationAddress).isValidSignature(hash, signature);
            if (magicValue != EIP1271_MAGICVALUE) revert InvalidContractSignature();
        }
    }

    /// @notice Hash hooks and return the hash
    /// @param hooks The hooks to hash
    function hashHooks(JamHooks.Def calldata hooks) external pure returns (bytes32) {
        return JamHooks.hash(hooks);
    }

    /// @notice Hash Jam order and return the hash
    /// @param order The order to hash
    /// @param hooksHash The hash of the hooks to include in the order hash, 0x000..00 if no hooks
    function hashJamOrder(JamOrder calldata order, bytes32 hooksHash) external view returns (bytes32) {
        if (order.usingPermit2){
            return keccak256(abi.encodePacked(
                "\x19\x01", PERMIT2.DOMAIN_SEPARATOR(), order.permit2OrderHash(hooksHash, address(balanceManager))
            ));
        } else {
            return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), order.hash(hooksHash)));
        }
    }

    /// @notice Cancel limit order by invalidating nonce for the sender address
    /// @param nonce The nonce to invalidate
    function cancelLimitOrder(uint256 nonce) external {
        invalidateOrderNonce(msg.sender, nonce, true);
    }

    /// @notice Check if taker's limit order nonce is valid
    /// @param taker address
    /// @param nonce to check
    /// @return True if nonce is valid
    function isLimitOrderNonceValid(address taker, uint256 nonce) external view returns (bool) {
        uint256 invalidatorSlot = nonce >> 8;
        uint256 invalidatorBit = 1 << (nonce & 0xff);
        return (limitOrdersNonces[taker][invalidatorSlot] & invalidatorBit) == 0;
    }

    /// @notice Validate order data and in case of standard approvals validate the signature
    /// @param order The order to validate
    /// @param signature The signature to validate
    /// @param hooksHash The hash of the hooks to include in the order hash
    function validateOrder(JamOrder calldata order, bytes calldata signature, bytes32 hooksHash) internal {
        // Allow settle from user without sig; For permit2 case, we already validated witness during the transfer
        if (order.taker != msg.sender && !order.usingPermit2) {
            bytes32 orderHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), order.hash(hooksHash)));
            validateSignature(order.taker, orderHash, signature);
        }
        if (!order.usingPermit2 || order.expiry == INF_EXPIRY){
            invalidateOrderNonce(order.taker, order.nonce, order.expiry == INF_EXPIRY);
        }
        require(
            order.executor == msg.sender || order.executor == address(0) || block.timestamp > order.exclusivityDeadline,
            InvalidExecutor()
        );
        require(order.buyTokens.length == order.buyAmounts.length, BuyTokensInvalidLength());
        require(order.sellTokens.length == order.sellAmounts.length, SellTokensInvalidLength());
        require(block.timestamp < order.expiry, OrderExpired());
    }

    /// @notice Check if nonce is valid and invalidate it
    /// @param taker address
    /// @param nonce The nonce to invalidate
    /// @param isLimitOrder True if it is a limit order
    function invalidateOrderNonce(address taker, uint256 nonce, bool isLimitOrder) private {
        require(nonce != 0, ZeroNonce());
        uint256 invalidatorSlot = nonce >> 8;
        uint256 invalidatorBit = 1 << (nonce & 0xff);
        mapping(uint256 => uint256) storage invalidNonces = isLimitOrder ? limitOrdersNonces[taker] : standardNonces[taker];
        uint256 invalidator = invalidNonces[invalidatorSlot];
        require(invalidator & invalidatorBit != invalidatorBit, InvalidNonce());
        invalidNonces[invalidatorSlot] = invalidator | invalidatorBit;
    }

    /// @notice validate if filled amounts are more than initial amounts that user signed
    /// @param filledAmounts The increased amounts to validate (if empty, return initial amounts)
    /// @param initialAmounts The initial amounts to validate against
    /// @return The filled amounts if exist, otherwise the initial amounts
    function validateFilledAmounts(
        uint256[] calldata filledAmounts, uint256[] calldata initialAmounts
    ) internal pure returns (uint256[] calldata){
        if (filledAmounts.length == 0) {
            return initialAmounts;
        }
        require(filledAmounts.length == initialAmounts.length, InvalidFilledAmountsLength());
        for (uint256 i; i < filledAmounts.length; ++i) {
            require(filledAmounts[i] >= initialAmounts[i], InvalidFilledAmounts(initialAmounts[i], filledAmounts[i]));
        }
        return filledAmounts;
    }

    /// @notice Validate batch data and all orders in a batch
    /// @param orders The orders to validate
    /// @param hooks The array of hooks corresponding to each order, or empty array if no hooks
    /// @param signatures The signatures corresponding to each order
    function validateBatchOrders(
        JamOrder[] calldata orders, JamHooks.Def[] calldata hooks, bytes[] calldata signatures
    ) internal {
        bool noHooks = hooks.length == 0;
        require(orders.length == signatures.length, InvalidBatchSignaturesLength());
        require(orders.length == hooks.length || noHooks, InvalidBatchHooksLength());
        for (uint i; i < orders.length; ++i) {
            require(orders[i].receiver != address(this), InvalidReceiverInBatch());
            validateOrder(orders[i], signatures[i], noHooks ? JamHooks.EMPTY_HOOKS_HASH : JamHooks.hash(hooks[i]));
        }
    }

    /// @notice Check if there are any duplicates in the array of tokens
    /// @param tokens The array of tokens to validate
    /// @return True if there are duplicates
    function hasDuplicates(address[] calldata tokens) internal pure returns (bool) {
        for (uint i; i < tokens.length - 1; ++i) {
            for (uint j = i + 1; j < tokens.length; ++j) {
                if (tokens[i] == tokens[j]) {
                    return true;
                }
            }
        }
        return false;
    }
}
