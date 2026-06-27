// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../interfaces/IMORC20.sol";
import "../interfaces/IMORC20Receiver.sol";
import "../executor/MapoExecutor.sol";
import "../lib/ExcessivelySafeCall.sol";
import "../lib/Helper.sol";

abstract contract MORC20Core is MapoExecutor, ERC165, IMORC20 {
    using ExcessivelySafeCall for address;
    using SafeERC20 for IERC20;
    using Address for address;

    bytes32 public constant INTERCHAIN_TRANSFER = keccak256("InterTransfer(bytes32,bytes)");
    bytes32 public constant INTERCHAIN_TRANSFER_AND_CALL = keccak256("InterTransferAndCall(bytes32,bytes)");
    bytes public constant NOT_CONTRACT_ADDRESS = "0x4e4f545f434f4e54524143545f41444452455353";

    mapping(bytes32 => bool) public orderList;

    constructor(address _mosAddress) MapoExecutor(_mosAddress) {}

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IMORC20).interfaceId || super.supportsInterface(interfaceId);
    }

    function estimateFee(
        uint256 _toChain,
        uint256 _gasLimit
    ) external view virtual override returns (address feeToken, uint256 fee) {
        return _getMessageFee(_toChain, _gasLimit);
    }

    function interTransfer(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount,
        uint256 _gasLimit
    ) external payable virtual override {
        _interTransfer(_fromAddress, _toChainId, _toAddress, _fromAmount, _gasLimit);
    }

    function interTransferAndCall(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount,
        uint256 _gasLimit,
        bytes memory _refundAddress,
        bytes memory _messageData
    ) external payable virtual override {
        _interTransferAndCall(
            _fromAddress,
            _toChainId,
            _toAddress,
            _fromAmount,
            _gasLimit,
            _refundAddress,
            _messageData
        );
    }

    function _interTransfer(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount,
        uint256 _gasLimit
    ) internal virtual {
        (uint256 amount, uint256 decimals) = _destroyTokenFrom(_fromAddress, _toChainId, _toAddress, _fromAmount);

        require(amount > 0, "MORC20Core: amount too small");

        bytes memory fromAddress = Helper._toBytes(_fromAddress);
        bytes memory prePayload = abi.encode(fromAddress, _toAddress, amount, decimals);
        bytes memory payload = abi.encode(INTERCHAIN_TRANSFER, prePayload);

        bytes32 orderId = _mosTransferOut(_toChainId, MESSAGE_TYPE_MESSAGE, payload, _gasLimit);

        emit InterTransfer(orderId, _fromAddress, _toChainId, _toAddress, _fromAmount);
    }

    function _interTransferAndCall(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount,
        uint256 _gasLimit,
        bytes memory _refundAddress,
        bytes memory _messageData
    ) internal virtual {
        (uint256 amount, uint256 decimals) = _destroyTokenFrom(_fromAddress, _toChainId, _toAddress, _fromAmount); // amount returned should not have dust
        require(amount > 0, "MORC20Core: amount too small");

        bytes memory fromAddress = Helper._toBytes(_fromAddress);
        bytes memory prePayload = abi.encode(fromAddress, _toAddress, amount, decimals, _refundAddress, _messageData);
        bytes memory payload = abi.encode(INTERCHAIN_TRANSFER_AND_CALL, prePayload);

        bytes32 orderId = _mosTransferOut(_toChainId, MESSAGE_TYPE_MESSAGE, payload, _gasLimit);

        emit InterTransferAndCall(orderId, _fromAddress, _toChainId, _toAddress, _fromAmount, prePayload);
    }

    function _interReceive(uint256 _fromChain, bytes32 _orderId, bytes memory _payload) internal virtual {
        (bytes memory fromBytes, bytes memory receiverBytes, uint256 amount, uint256 decimals) = abi.decode(
            _payload,
            (bytes, bytes, uint256, uint256)
        );
        address receiverAddress = Helper._fromBytes(receiverBytes);
        _createTokenTo(receiverAddress, _fromChain, amount, decimals);

        emit InterReceive(_orderId, _fromChain, fromBytes, receiverAddress, amount);
    }

    function callOnMORC20Received(
        uint256 _fromChainId,
        bytes memory _fromAddress,
        uint256 _amount,
        address _receiverAddress,
        bytes32 _orderId,
        bytes calldata _message
    ) public virtual {
        require(_msgSender() == address(this), "MORC20Core: caller must be MORC20Core");

        // send
        uint256 amount = _transferFrom(address(this), _receiverAddress, _amount);
        emit InterReceive(_orderId, _fromChainId, _fromAddress, _receiverAddress, amount);

        // call
        // todo: check the gas for call
        bool success = IMORC20Receiver(_receiverAddress).onMORC20Received{gas: gasleft()}(
            _fromChainId,
            _fromAddress,
            _amount,
            _orderId,
            _message
        );
        require(success, "MORC20Core: callOnMORC20Received fail");
    }

    function _interReceiveAndExecute(uint256 _fromChain, bytes32 _orderId, bytes memory _payload) internal virtual {
        (
            bytes memory srcAddress,
            bytes memory receiverBytes,
            uint256 amount,
            uint256 decimals,
            bytes memory refundBytes,
            bytes memory messageData
        ) = abi.decode(_payload, (bytes, bytes, uint256, uint256, bytes, bytes));

        address receiverAddress = Helper._fromBytes(receiverBytes);
        (uint256 amount_, ) = _createTokenTo(address(this), _fromChain, amount, decimals);

        if (!receiverAddress.isContract()) {
            _transferFrom(address(this), Helper._fromBytes(refundBytes), amount_);
            emit InterReceive(_orderId, _fromChain, srcAddress, Helper._fromBytes(refundBytes), amount_);
            emit InterReceiveAndExecute(_orderId, _fromChain, srcAddress, receiverAddress, false, NOT_CONTRACT_ADDRESS);
            return;
        }

        bytes memory callOnMORC20ReceivedSelector = abi.encodeWithSelector(
            this.callOnMORC20Received.selector,
            _fromChain,
            srcAddress,
            amount_,
            receiverAddress,
            _orderId,
            messageData
        );

        (bool success, bytes memory reason) = address(this).excessivelySafeCall(
            gasleft(),
            150,
            callOnMORC20ReceivedSelector
        );

        if (success) {
            emit InterReceiveAndExecute(_orderId, _fromChain, srcAddress, receiverAddress, true, bytes(""));
        } else {
            _transferFrom(address(this), Helper._fromBytes(refundBytes), amount_);
            emit InterReceive(_orderId, _fromChain, srcAddress, Helper._fromBytes(refundBytes), amount_);
            emit InterReceiveAndExecute(_orderId, _fromChain, srcAddress, receiverAddress, false, reason);
        }
    }

    function _execute(
        uint256 _fromChain,
        uint256,
        bytes memory,
        bytes32 _orderId,
        bytes memory _message
    ) internal virtual override returns (bytes memory) {
        require(!orderList[_orderId], "MORC20Core: invalid orderId");

        (bytes32 interType, bytes memory payload) = abi.decode(_message, (bytes32, bytes));

        orderList[_orderId] = true;

        if (interType == INTERCHAIN_TRANSFER) {
            _interReceive(_fromChain, _orderId, payload);
        } else if (interType == INTERCHAIN_TRANSFER_AND_CALL) {
            _interReceiveAndExecute(_fromChain, _orderId, payload);
        } else {
            revert("MORC20Core: unknown message type");
        }

        return payload;
    }

    // burn or lock omnichain token
    function _destroyTokenFrom(
        address _fromAddress,
        uint256 _toChainId,
        bytes memory _toAddress,
        uint256 _fromAmount
    ) internal virtual returns (uint256 amount, uint256 decimals);

    // mint or unlock omnichain token
    function _createTokenTo(
        address _receiverAddress,
        uint256 _fromChainId,
        uint256 _amount,
        uint256 _decimals
    ) internal virtual returns (uint256 amount, uint256 decimals);

    function _transferFrom(address _from, address _to, uint256 _amount) internal virtual returns (uint256);

    function currentChainSupply() public view virtual override returns (uint);

    function token() public view virtual override returns (address);
}
