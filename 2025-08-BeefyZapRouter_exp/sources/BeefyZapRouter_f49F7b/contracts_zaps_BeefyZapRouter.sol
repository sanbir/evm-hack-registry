// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { BytesLib } from "solidity-bytes-utils/contracts/BytesLib.sol";

import { IBeefyTokenManager } from "../interfaces/IBeefyTokenManager.sol";
import { IBeefyZapRouter } from "../interfaces/IBeefyZapRouter.sol";
import { IPermit2 } from "../interfaces/IPermit2.sol";
import { BeefyTokenManager} from "./BeefyTokenManager.sol";
import { ZapErrors } from "./ZapErrors.sol";

/**
 * @title Zap router for Beefy vaults
 * @author kexley, Beefy
 * @notice Adaptable router for zapping tokens to and from Beefy vaults
 * @dev Router that allows arbitary calls to external contracts. Users can zap directly or sign 
 * using Permit2 to allow a relayer to execute zaps on their behalf. Do not directly approve this
 * contract for spending your tokens, approve the TokenManager instead
 */
contract BeefyZapRouter is IBeefyZapRouter, ZapErrors, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    /**
     * @dev Witness string used in signing an order
     */
    string private constant ORDER_STRING =
        "Order order)Order(Input[] inputs,Output[] outputs,Relay relay,address user,address recipient)Input(address token,uint256 amount)Output(address token,uint256 minOutputAmount)Relay(address target,uint256 value,bytes data)TokenPermissions(address token,uint256 amount)";
    /**
     * @dev Witness typehash used in signing an order
     */
    bytes32 private constant ORDER_TYPEHASH = 
        keccak256("Order(Input[] inputs,Output[] outputs,Relay relay,address user,address recipient)Input(address token,uint256 amount)Output(address token,uint256 minOutputAmount)Relay(address target,uint256 value,bytes data)");
    /**
     * @notice Permit2 immutable address
     */
    address public immutable permit2;
    /**
     * @notice Token manager immutable address
     */
    address public immutable tokenManager;

    /**
     * @notice Token and amount sent to the recipient at end of a zap
     * @param token Address of the token sent to recipient
     * @param amount Amount of the token sent to the recipient
     */
    event TokenReturned(address indexed token, uint256 amount);
    /**
     * @notice External relay call at end of zap
     * @param target Address of the target
     * @param value Ether value of the call
     * @param data Payload of the external call
     */
    event RelayData(address indexed target, uint256 value, bytes data);
    /**
     * @notice Completed order
     * @param order Order that has been fulfilled
     * @param caller Address of the order's executor
     * @param recipient Address of the order's recipient
     */
    event FulfilledOrder(Order indexed order, address indexed caller, address indexed recipient);

    /**
     * @dev Initialize permit2 address and create an implementation of the token manager
     * @param _permit2 Address for the permit2 contract
     */
    constructor(address _permit2) {
        permit2 = _permit2;
        tokenManager = address(new BeefyTokenManager());
    }

    /**
     * @notice Execute an order directly
     * @dev The user executes their own order directly. User must have already approved the token
     * manager to move the tokens
     * @param _order Order containing how many tokens to pull and the slippage amounts on outputs
     * @param _route Route containing the steps to reach the output
     */
    function executeOrder(Order calldata _order, Step[] calldata _route) external payable nonReentrant whenNotPaused {
        if (msg.sender != _order.user) revert InvalidCaller(_order.user, msg.sender);

        IBeefyTokenManager(tokenManager).pullTokens(_order.user, _order.inputs);
        _executeOrder(_order, _route);
    }

    /**
     * @notice Execute an order using a signature from the input token owner
     * @dev Execute an order indirectly by passing a signed permit from Permit2 that contains the
     * order as witness data. The user who owns the tokens must have already approved Permit2.
     * Route is supplied at this stage as slippages and amounts are already set in the signed order
     * @param _permit Struct of tokens that have been permitted and the nonce/deadline
     * @param _order Order that details the input/output tokens and amounts
     * @param _signature Resulting string from signing the permit and order data
     * @param _route Actual steps that will transform input tokens to output tokens
     */
    function executeOrder(
        IPermit2.PermitBatchTransferFrom calldata _permit,
        Order calldata _order,
        bytes calldata _signature,
        Step[] calldata _route
    ) external nonReentrant whenNotPaused {
        IPermit2(permit2).permitWitnessTransferFrom(
            _permit,
            _getTransferDetails(_order.inputs),
            _order.user,
            keccak256(abi.encode(ORDER_TYPEHASH, _order)),
            ORDER_STRING,
            _signature
        );

        _executeOrder(_order, _route);
    }

    /**
     * @dev Executes a valid order by executing the steps on the route, validating the output
     * amounts and then sending them to the recipient. A final external call is made to relay
     * data in the order to chain together calls
     * @param _order Order struct with details of inputs and outputs
     * @param _route Actual steps to transform inputs to outputs
     */
    function _executeOrder(Order calldata _order, Step[] calldata _route) private {
        _executeSteps(_route);
        _returnAssets(_order.outputs, _order.recipient, _order.relay.value);
        _executeRelay(_order.relay);

        emit FulfilledOrder(_order, msg.sender, _order.recipient);
    }

    /**
     * @dev Executes various steps to achieve the order outputs by making external calls. Balance
     * data is dynamically inserted into payloads to always move the full balances of this contract
     * @param _route Array of the steps the contract will execute
     */
    function _executeSteps(Step[] calldata _route) private {
        uint256 routeLength = _route.length;
        for (uint256 i; i < routeLength;) {
            Step calldata step = _route[i];
            (
                address stepTarget,
                uint256 value,
                bytes memory callData,
                StepToken[] calldata stepTokens
            ) = (step.target, step.value, step.data, step.tokens);

            if (stepTarget == permit2 || stepTarget == tokenManager) revert TargetingInvalidContract(stepTarget);

            uint256 balance;
            uint256 callDataLength = callData.length;
            uint256 stepTokensLength = stepTokens.length;

            for (uint256 j; j < stepTokensLength;) {
                StepToken calldata stepToken = stepTokens[j];
                (address stepTokenAddress, int32 stepTokenIndex) = (stepToken.token, stepToken.index);

                if (stepTokenAddress == address(0)) {
                    value = address(this).balance;
                } else {
                    balance = IERC20(stepTokenAddress).balanceOf(address(this));
                    _approveToken(stepTokenAddress, stepTarget, balance);

                    if (stepTokenIndex >= 0) {
                        uint256 idx = uint256(int256(stepTokenIndex));
                        callData = bytes.concat(
                            callData.slice(0, idx),
                            abi.encode(balance),
                            callData.slice(idx + 32, callDataLength - (idx + 32))
                        );
                    }
                }

                unchecked {
                    ++j;
                }
            }

            (bool success, bytes memory result) = stepTarget.call{value: value}(callData);
            if (!success) _propagateError(stepTarget, value, callData, result);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Approve a token to be spent by an address if not already approved enough
     * @param _token Address of token to be approved
     * @param _spender Address of spender that will be allowed to move tokens
     * @param _amount Number of tokens that are going to be spent
     */
    function _approveToken(address _token, address _spender, uint256 _amount) private {
        if (IERC20(_token).allowance(address(this), _spender) < _amount) {
            IERC20(_token).forceApprove(_spender, type(uint256).max);
        }
    }

    /**
     * @dev Bubble up an error message from an underlying contract
     * @param _target Address that the call was sent to
     * @param _value Amount of ether sent with the call
     * @param _data Payload data of the call
     * @param _returnedData Returned data from the call
     */
    function _propagateError(address _target, uint256 _value, bytes memory _data, bytes memory _returnedData)
        private
        pure
    {
        if (_returnedData.length == 0) revert CallFailed(_target, _value, _data);
        assembly {
            revert(add(32, _returnedData), mload(_returnedData))
        }
    }

    /**
     * @dev Return the outputs to the recipient address
     * @param _outputs Token addresses and amounts to validate against to ensure no major slippage
     * @param _recipient Address of the receiver of the outputs
     * @param _relayValue Unwrapped native amount that is reserved for calling the relay address
     */
    function _returnAssets(Output[] calldata _outputs, address _recipient, uint256 _relayValue) private {
        uint256 balance;
        uint256 outputsLength = _outputs.length;
        for (uint256 i; i < outputsLength;) {
            Output calldata output = _outputs[i];
            (address outputToken, uint256 outputMinAmount) = (output.token, output.minOutputAmount);
            if (outputToken == address(0)) {
                balance = address(this).balance;
                if (balance < outputMinAmount) {
                    revert Slippage(outputToken, outputMinAmount, balance);
                }
                if (balance > _relayValue) {
                    balance -= _relayValue;
                    (bool success,) = _recipient.call{value: balance}("");
                    if (!success) revert EtherTransferFailed(_recipient);
                }
            } else {
                balance = IERC20(outputToken).balanceOf(address(this));
                if (balance < outputMinAmount) {
                    revert Slippage(outputToken, outputMinAmount, balance);
                } else if (balance > 0) {
                    IERC20(outputToken).safeTransfer(_recipient, balance);
                }
            }

            emit TokenReturned(outputToken, balance);

            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev Call an external contract at the end of a zap with a payload signed in the order
     * @param _relay Target address and payload data in a struct
     */
    function _executeRelay(Relay calldata _relay) private {
        (address relayTarget, uint256 relayValue, bytes calldata relaydata) 
            = (_relay.target, _relay.value, _relay.data);
        if (relayTarget != address(0)) {
            if (relayTarget == permit2 || relayTarget == tokenManager) {
                revert TargetingInvalidContract(relayTarget);
            }

            if (address(this).balance < relayValue) {
                revert InsufficientRelayValue(address(this).balance, relayValue);
            }

            (bool success, bytes memory result) = relayTarget.call{value: relayValue}(relaydata);
            if (!success) _propagateError(relayTarget, relayValue, relaydata, result);

            emit RelayData(relayTarget, relayValue, relaydata);
        }
    }

    /**
     * @dev Parse the token transfer details from the order so it can be supplied to the Permit2
     * transfer from request
     * @param _inputs Token addresses and amounts in a struct
     * @return transferDetails Transformed data
     */
    function _getTransferDetails(Input[] calldata _inputs)
        private
        view
        returns (IPermit2.SignatureTransferDetails[] memory)
    {
        uint256 inputsLength = _inputs.length;
        IPermit2.SignatureTransferDetails[] memory transferDetails =
            new IPermit2.SignatureTransferDetails[](inputsLength);
        
        for (uint256 i; i < inputsLength;) {
            transferDetails[i] =
                IPermit2.SignatureTransferDetails({to: address(this), requestedAmount: _inputs[i].amount});

            unchecked {
                ++i;
            }
        }
        return transferDetails;
    }

    /**
     * @notice Pause the contract from carrying out any more zaps
     * @dev Only owner can pause
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract to allow new zaps
     * @dev Only owner can unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Allow receiving of native tokens
     */
    receive() external payable {}
}
