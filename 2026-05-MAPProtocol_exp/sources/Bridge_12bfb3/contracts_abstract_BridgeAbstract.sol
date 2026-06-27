// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {IButterBridgeV3} from "../interface/IButterBridgeV3.sol";
import {IMOSV3} from "../interface/IMOSV3.sol";
import {IMintableToken} from "../interface/IMintableToken.sol";
import {IMapoExecutor} from "../interface/IMapoExecutor.sol";
import {ISwapOutLimit} from "../interface/ISwapOutLimit.sol";
import {IButterReceiver} from "../interface/IButterReceiver.sol";
import {IFeeService} from "../interface/IFeeService.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {AccessManagedUpgradeable} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {EvmDecoder} from "../lib/EvmDecoder.sol";
import {MessageInEvent} from "../lib/Types.sol";
import {Helper} from "../lib/Helper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract BridgeAbstract is
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    AccessManagedUpgradeable,
    IButterBridgeV3,
    IMOSV3
{
    address internal constant ZERO_ADDRESS = address(0);
    uint256 constant MINTABLE_TOKEN = 0x01;
    uint256 constant MIN_GAS_CALL_ONRECEIVED = 300_000;

    uint256 public immutable selfChainId = block.chainid;

    uint256 private nonce;

    address internal wToken;
    IFeeService internal feeService;
    ISwapOutLimit internal swapLimit;

    mapping(address => uint256) public trustList;

    mapping(bytes32 => uint256) public orderList;

    // token => feature
    mapping(address => uint256) public tokenFeatureList;
    // chainId => (token => info)
    mapping(uint256 => mapping(address => uint256)) public tokenMappingList;

    // service fee or bridge fee
    // address => (token => amount)
    mapping(address => mapping(address => uint256)) public feeList;

    error order_exist();
    error invalid_order_Id();
    error invalid_bridge_log();
    error invalid_pack_version();
    error in_amount_low();
    error insufficient_token();

    error token_not_registered();
    error zero_address();
    error not_contract();
    error zero_amount();
    error invalid_mos_contract();
    error length_mismatching();
    error bridge_same_chain();
    error not_support_value();
    error not_support_target_chain();
    error unsupported_message_type();
    error retry_verify_fail();
    error bubbling(bytes e);

    error insufficient_liquidity();
    error token_transfer_fail();
    error failed_receiver_not_set();
    error call_on_received_gas_too_low();

    event SetContract(uint256 t, address addr);
    event SetFailedReceiver(address _failedreceiver);
    event RegisterToken(address token, uint256 toChain, bool enable);
    event UpdateToken(address token, uint256 feature);
    event UpdateTrust(address trustAddress, bool enable);
    event WithdrawFee(address receiver, address token, uint256 amount);
    event GasInfo(bytes32 indexed orderId, uint256 indexed executingGas, uint256 indexed executedGas);

    event MessageTransfer(
        address initiator,
        address referrer,
        address sender,
        bytes32 orderId,
        bytes32 transferId,
        address feeToken,
        uint256 fee
    );

    receive() external payable {}

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _wToken, address _defaultAdmin) public initializer {
        _checkAddress(_wToken);
        // _checkAddress(_defaultAdmin);
        if(!Helper._isContract(_defaultAdmin)) revert not_contract();
        __Pausable_init();
        __ReentrancyGuard_init();
        __AccessManaged_init(_defaultAdmin);
        wToken = _wToken;
    }

    // --------------------------------------------- manage ----------------------------------------------
    function trigger() external restricted {
        paused() ? _unpause() : _pause();
    }

    function registerTokenChains(address _token, uint256[] memory _toChains, bool _enable) external restricted {
        if (!Helper._isContract(_token)) revert not_contract();
        for (uint256 i = 0; i < _toChains.length; i++) {
            uint256 toChain = _toChains[i];
            uint256 enable = _enable ? 0x01 : 0x00;
            tokenMappingList[toChain][_token] = enable;
            emit RegisterToken(_token, toChain, _enable);
        }
    }

    function updateTokens(address[] calldata _tokens, uint256 _feature) external restricted {
        for (uint256 i = 0; i < _tokens.length; i++) {
            tokenFeatureList[_tokens[i]] = _feature;
            emit UpdateToken(_tokens[i], _feature);
        }
    }

    function setTrustAddress(address _addr, bool _enable) external restricted {
        uint256 enable = _enable ? 0x01 : 0x00;
        trustList[_addr] = enable;
        emit UpdateTrust(_addr, _enable);
    }

    // --------------------------------------------- external view -------------------------------------------
    function isMintable(address _token) external view returns (bool) {
        return _isMintable(_token);
    }

    function isBridgeable(address _token, uint256 _toChain) external view returns (bool) {
        return ((tokenMappingList[_toChain][_token] & 0x0F) == 0x01);
    }

    function getOrderStatus(
        uint256,
        uint256 _blockNum,
        bytes32 _orderId
    ) external view virtual override returns (bool exists, bool verifiable, uint256 nodeType) {}

    function getMessageFee(
        uint256 _toChain,
        address _feeToken,
        uint256 _gasLimit
    ) external view returns (uint256 fee, address receiver) {
        (fee, receiver) = _getMessageFee(_toChain, _feeToken, _gasLimit);
    }

    // --------------------------------------------- external ---------------------------------------------
    function withdrawFee(address receiver, address token) external payable nonReentrant {
        uint256 amount = feeList[receiver][token];
        if (amount > 0) {
            _tokenTransferOut(token, receiver, amount, true);
            feeList[receiver][token] = 0;
        }
        emit WithdrawFee(receiver, token, amount);
    }

    function transferOut(
        uint256 _toChain,
        bytes memory _messageData,
        address _feeToken
    ) external payable virtual override returns (bytes32 orderId) {}

    function swapOutToken(
        address _sender, // initiator address
        address _token, // src token
        bytes memory _to,
        uint256 _amount,
        uint256 _toChain, // target chain id
        bytes calldata _swapData
    ) external payable virtual override returns (bytes32 orderId) {}

    function depositToken(
        address _token,
        address to,
        uint256 _amount
    ) external payable virtual returns (bytes32 orderId) {}

    function retryMessageIn(
        uint256 _fromChain,
        bytes32 _orderId,
        address _token,
        uint256 _amount,
        bytes calldata _fromAddress,
        bytes calldata _swapData,
        bytes calldata _retryMessage
    ) external virtual {}

    // --------------------------------------------- internal ---------------------------------------------

    function _transferOut(
        uint256 _fromChain,
        uint256 _toChain,
        bytes calldata _messageData,
        address _feeToken
    ) internal virtual returns (MessageData memory msgData) {
        if (_toChain == _fromChain) revert bridge_same_chain();

        msgData = abi.decode(_messageData, (MessageData));
        if (msgData.value != 0) revert not_support_value();
        if (msgData.msgType != MessageType.MESSAGE) revert unsupported_message_type();

        (uint256 amount, address receiverFeeAddress) = _getMessageFee(_toChain, _feeToken, msgData.gasLimit);

        _tokenTransferIn(_feeToken, msg.sender, amount, false, false);
        feeList[receiverFeeAddress][_feeToken] += amount;
    }

    // message in
    function _transferIn(MessageInEvent memory _inEvent, bool _gasleft, bool _revertError) internal {
        address to = Helper._fromBytes(_inEvent.to);

        uint256 gasLeft = gasleft();
        uint256 gasLimit = _gasleft ? gasLeft : _inEvent.gasLimit;

        if (!Helper._isContract(to)) {
            return _emitMessageIn(_inEvent.from, _inEvent, false, gasLeft, bytes("NotContract"));
            //return _storeMessageData(_inEvent, bytes("NotContract"), 0);
        }

        try
            IMapoExecutor(to).mapoExecute{gas: gasLimit}(
                _inEvent.fromChain,
                _inEvent.toChain,
                _inEvent.from,
                _inEvent.orderId,
                _inEvent.swapData
            )
        {
            _emitMessageIn(_inEvent.from, _inEvent, true, gasLeft, "");
        } catch Error(string memory reason) {
            if (_revertError) {
                revert(reason);
            }
            _emitMessageIn(_inEvent.from, _inEvent, false, gasLeft, bytes(reason));
        } catch (bytes memory reason) {
            if (_revertError) {
                revert bubbling(reason);
            }
            _emitMessageIn(_inEvent.from, _inEvent, false, gasLeft, reason);
        }
    }

    function _swapIn(MessageInEvent memory _inEvent) internal {
        address to = Helper._fromBytes(_inEvent.to);
        uint256 gasLeft = gasleft();
        _checkLiquidity(_inEvent.token, _inEvent.amount);
        if (_inEvent.swapData.length > 0 && Helper._isContract(to)) {
            // if swap params is not empty, then we need to do swap on current chain
            bool result;
            (_inEvent.token, result) = _tokenTransferOutCatch(_inEvent.token, to, _inEvent.amount, false);
            if (result) {
                if(gasleft() < MIN_GAS_CALL_ONRECEIVED) revert call_on_received_gas_too_low();
                try
                    IButterReceiver(to).onReceived(
                        _inEvent.orderId,
                        _inEvent.token,
                        _inEvent.amount,
                        _inEvent.fromChain,
                        _inEvent.from,
                        _inEvent.swapData
                    )
                {} catch {}
            } else {
                _tokenTransferOut(_inEvent.token, _getTransferOutFailedReceiverAndCheck(), _inEvent.amount, false);
            }
        } else {
            // transfer token if swap did not happen
            bool result;
            (_inEvent.token, result) = _tokenTransferOutCatch(_inEvent.token, to, _inEvent.amount, true);
            if (!result) {
                _tokenTransferOut(_inEvent.token, _getTransferOutFailedReceiverAndCheck(), _inEvent.amount, true);
            }
        }
        _emitMessageIn(_inEvent.from, _inEvent, true, gasLeft, "");
    }

    function _tokenTransferIn(
        address _token,
        address _from,
        uint256 _amount,
        bool _wrap,
        bool _checkBurn
    ) internal returns (address inToken) {
        inToken = _token;
        if (_token == ZERO_ADDRESS) {
            if (msg.value < _amount) revert in_amount_low();
            if (_wrap) {
                Helper._safeDeposit(wToken, _amount);
                inToken = wToken;
            }
        } else {
            uint256 balanceBefore = Helper._getBalance(_token, address(this));
            Helper._safeTransferFrom(_token, _from, address(this), _amount);
            uint256 balanceAfter = Helper._getBalance(_token, address(this));
            if(balanceAfter < (balanceBefore + _amount)) revert in_amount_low();
            if (_checkBurn) {
                _checkAndBurn(_token, _amount);
            }
        }
    }

    function _tokenTransferOut(
        address _token,
        address _receiver,
        uint256 _amount,
        bool _unwrap
    ) internal returns (address token) {
        bool result;
        (token, result) = _tokenTransferOutCatch(_token, _receiver, _amount, _unwrap);
        if(!result) revert token_transfer_fail();
    }

    function _tokenTransferOutCatch(
        address _token,
        address _receiver,
        uint256 _amount,
        bool _unwrap
    ) internal returns (address token, bool result) {
        token = _token;
        if (_token == ZERO_ADDRESS) {
            result = Helper._transferNativeCatch(_receiver, _amount);
        } else if (_token == wToken && _unwrap) {
            Helper._safeWithdraw(wToken, _amount);
            token = ZERO_ADDRESS;
            result = Helper._transferNativeCatch(_receiver, _amount);
        } else {
            result = Helper._transferCatch(_token,_receiver, _amount);
        }
    }

    function _checkLiquidity(address _token, uint256 _amount) internal view {
        uint256 balance = Helper._getBalance(_token, address(this));
        if(_amount > balance) revert insufficient_liquidity();
    }

    function _notifyLightClient(uint256 _chainId) internal virtual {}

    // messageType,fromChain,toChain,gasLimit,mos,to,token,amount,swapData
    function _messageOut(
        bool _notify,
        bool _relay,
        address _initiator,
        address _sender,
        MessageInEvent memory _inEvent
    ) internal returns (bytes32 orderId) {
        uint256 header = EvmDecoder.encodeMessageHeader(_relay, _inEvent.messageType);

        if (_inEvent.toChain == _inEvent.fromChain) revert bridge_same_chain();
        if (_inEvent.mos == ZERO_ADDRESS) revert invalid_mos_contract();

        address initiator = (trustList[_sender] == 0x01) ? _initiator : _sender;

        uint256 chainAndGasLimit = _getChainAndGasLimit(_inEvent.fromChain, _inEvent.toChain, _inEvent.gasLimit);

        if(_inEvent.orderId == bytes32(0)) orderId = _getOrderId(_inEvent.fromChain, _inEvent.toChain, _sender, _inEvent.to);
        else orderId = _inEvent.orderId;
        bytes memory payload = abi.encode(
            header,
            _inEvent.mos,
            _inEvent.token,
            _inEvent.amount,
            initiator,
            _sender,
            _inEvent.to,
            _inEvent.swapData
        );

        emit MessageOut(orderId, chainAndGasLimit, payload);

        if (_notify) {
            _notifyLightClient(_inEvent.toChain);
        }
    }

    function _emitMessageIn(
        bytes memory _initiator,
        MessageInEvent memory _inEvent,
        bool success,
        uint256 _gasBefore,
        bytes memory _reason
    ) internal {
        uint256 gasUsed = (_gasBefore > 0) ? (_gasBefore - gasleft()) : 0;
        uint256 chainAndGasLimit = _getChainAndGasLimit(
            uint64(_inEvent.fromChain),
            uint64(_inEvent.toChain),
            uint64(gasUsed)
        );

        if (success) {
            emit MessageIn(
                _inEvent.orderId,
                chainAndGasLimit,
                _inEvent.token,
                _inEvent.amount,
                Helper._fromBytes(_inEvent.to),
                _inEvent.from,
                bytes(""),
                true,
                bytes("")
            );
        } else {
            _storeMessageData(_initiator, _inEvent, _reason, chainAndGasLimit);
        }
    }

    function _storeMessageData(
        bytes memory _initiator,
        MessageInEvent memory _inEvent,
        bytes memory _reason,
        uint256 _chainAndGasLimit
    ) internal {
        orderList[_inEvent.orderId] = uint256(_getStoreMessageHash(_initiator, _inEvent));
        bytes memory payload = abi.encode(
            _inEvent.messageType,
            _inEvent.gasLimit,
            _initiator,
            _inEvent.to,
            _inEvent.swapData
        );
        emit MessageIn(
            _inEvent.orderId,
            _chainAndGasLimit,
            _inEvent.token,
            _inEvent.amount,
            Helper._fromBytes(_inEvent.to),
            _inEvent.from,
            payload,
            false,
            _reason
        );
    }

    function _getStoredMessage(
        uint256 _chainAndGas,
        bytes32 _orderId,
        address _token,
        uint256 _amount,
        bytes calldata _fromAddress,
        bytes calldata _swapData
    ) internal returns (bytes memory initiator, MessageInEvent memory inEvent) {
        (inEvent.fromChain, inEvent.toChain, ) = EvmDecoder._decodeChainAndGasLimit(_chainAndGas);
        (inEvent.messageType, inEvent.gasLimit, initiator, inEvent.to, inEvent.swapData) = abi.decode(
            _swapData,
            (uint8, uint256, bytes, bytes, bytes)
        );
        inEvent.token = _token;
        inEvent.amount = _amount;
        inEvent.from = _fromAddress;
        bytes32 retryHash = _getStoreMessageHash(initiator, inEvent);
        
        if (uint256(retryHash) != orderList[_orderId]) revert retry_verify_fail();

        //inEvent.fromChain = _fromChain;
        inEvent.orderId = _orderId;
        inEvent.token = _token;
        inEvent.amount = _amount;
        inEvent.from = _fromAddress;

        orderList[_orderId] = 0x01;
    }
    function _getStoreMessageHash(
        bytes memory _initiator,
        MessageInEvent memory inEvent
    ) internal pure returns (bytes32 hash) {
        hash = keccak256(
            abi.encode(
                inEvent.messageType,
                inEvent.fromChain,
                inEvent.toChain,
                inEvent.token,
                inEvent.amount,
                inEvent.gasLimit,
                _initiator,
                inEvent.from,
                inEvent.to,
                keccak256(inEvent.swapData)
            )
        );
        
    }

    function _getOrderId(
        uint256 _fromChain,
        uint256 _toChain,
        address _from,
        bytes memory _to
    ) internal returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), nonce++, _fromChain, _toChain, _from, _to));
    }
    function _getTransferOutFailedReceiverAndCheck() internal view returns(address failedReceiver) {
        failedReceiver = getTransferOutFailedReceiver();
        if(failedReceiver == address(0)) revert failed_receiver_not_set();
    }

    function getTransferOutFailedReceiver() public view virtual returns(address) {}


    function _getMessageFee(
        uint256 _toChain,
        address _feeToken,
        uint256 _gasLimit
    ) internal view returns (uint256 amount, address receiverAddress) {
        (amount, receiverAddress) = feeService.getServiceMessageFee(_toChain, _feeToken, _gasLimit);
        if (amount == 0) revert not_support_target_chain();
    }

    function _checkAddress(address _address) internal pure {
        if (_address == ZERO_ADDRESS) revert zero_address();
    }

    function _checkBridgeable(address _token, uint256 _chainId) internal view {
        if ((tokenMappingList[_chainId][_token] & 0x0F) != 0x01) revert token_not_registered();
    }

    function _checkAndBurn(address _token, uint256 _amount) internal {
        if (_isMintable(_token)) {
            IMintableToken(_token).burn(_amount);
        }
    }

    function _checkAndMint(address _token, uint256 _amount) internal {
        if (_isMintable(_token)) {
            IMintableToken(_token).mint(address(this), _amount);
        }
    }

    function _isMintable(address _token) internal view returns (bool) {
        return (tokenFeatureList[_token] & MINTABLE_TOKEN) == MINTABLE_TOKEN;
    }

    function _checkLimit(uint256 amount, uint256 tochain, address token) internal {
        if (address(swapLimit) != ZERO_ADDRESS) swapLimit.checkLimit(amount, tochain, token);
    }

    function _checkOrder(bytes32 _orderId) internal {
        if (orderList[_orderId] >= 0x01) revert order_exist();
        orderList[_orderId] = 0x01;
    }

    function _getChainAndGasLimit(
        uint256 _fromChain,
        uint256 _toChain,
        uint256 _gasLimit
    ) internal pure returns (uint256 chainAndGasLimit) {
        chainAndGasLimit = ((_fromChain << 192) | (_toChain << 128) | _gasLimit);
    }

    /** UUPS *********************************************************/
    function _authorizeUpgrade(address) internal override restricted {
        // if (!hasRole(UPGRADER_ROLE, msg.sender)) revert only_upgrade_role();
    }

    function getImplementation() external view returns (address) {
        return ERC1967Utils.getImplementation();
        // return _getImplementation();
    }
}
