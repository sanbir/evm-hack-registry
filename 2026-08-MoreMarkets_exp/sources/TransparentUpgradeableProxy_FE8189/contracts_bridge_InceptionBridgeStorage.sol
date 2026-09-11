// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
pragma abicoder v2;

import "../interfaces/IInceptionBridge.sol";
import "../interfaces/IInceptionBridgeErrors.sol";

/// @author The InceptionLRT team
/// @title The InceptionBridgeStorage contract
/// @notice Stores variables for the InceptionBridge contract and facilitates their updates.
abstract contract InceptionBridgeStorage is
    IInceptionBridgeStorage,
    IInceptionBridgeErrors
{
    uint256 internal constant _PROOF_LENGTH = 0x100;

    uint256 internal _globalNonce;
    address public notary;

    mapping(bytes32 => bool) internal _usedProofs;
    mapping(uint256 => address) internal _bridgeAddressByChainId;

    /// @dev keccak256(fromToken,fromChain,_bridgeAddressByChainId(destinationChain), destinationChain) => destinationToken
    mapping(bytes32 => address) internal _destinationTokens;

    uint256 public shortCapDuration;
    /// @dev token => Cap per 'shortCapTime'
    mapping(address => uint256) public shortCaps;

    /// @dev token => (epochTime/shortCapDuration) => Current Deposits
    mapping(address => mapping(uint256 => uint256)) public shortCapsDeposit;
    /// @dev token => (epochTime/shortCapDuration) => Current Withdraws
    mapping(address => mapping(uint256 => uint256)) public shortCapsWithdraw;

    uint256 public longCapDuration;
    /// @dev token => cap per 'longCapTime'
    mapping(address => uint256) public longCaps;
    /// @dev token => (epochTime/longCapDuration) => Current Deposits
    mapping(address => mapping(uint256 => uint256)) public longCapsDeposit;
    /// @dev token => (epochTime/longCapDuration) => Current Withdraws
    mapping(address => mapping(uint256 => uint256)) public longCapsWithdraw;

    address internal _previousSender;
    uint256 internal _previousDepositBlockNum;

    /// token -> lockbox
    mapping(address => address) public xerc20TokenRegistry;

    /// @notice WARNING: Keep it up-to-date
    uint256[50 - 16] private __gap;

    function __initInceptionBridgeStorage(address notaryAddress) internal {
        _setNotary(notaryAddress);
        _setDefaultCrosschainThreshold();
    }

    function _beforeDeposit() internal {
        if (_previousSender != address(0) && _previousDepositBlockNum != 0) {
            if (
                _previousSender == tx.origin &&
                _previousDepositBlockNum == block.number
            ) {
                revert MultipleDeposits();
            }
        }
        _previousSender = tx.origin;
        _previousDepositBlockNum = block.number;
    }

    function _updateDepositCaps(address fromToken, uint256 amount) internal {
        /// Short(default: per hour)
        if (
            shortCapsDeposit[fromToken][getCurrentStamp(shortCapDuration)] +
                amount >
            shortCaps[fromToken]
        ) {
            revert ShortCapExceeded(
                shortCaps[fromToken],
                shortCapsDeposit[fromToken][getCurrentStamp(shortCapDuration)] +
                    amount
            );
        }
        shortCapsDeposit[fromToken][
            getCurrentStamp(shortCapDuration)
        ] += amount;
        /// Long(default: per day)
        if (
            longCapsDeposit[fromToken][getCurrentStamp(longCapDuration)] +
                amount >
            longCaps[fromToken]
        ) {
            revert LongCapExceeded(
                longCaps[fromToken],
                longCapsDeposit[fromToken][getCurrentStamp(longCapDuration)] +
                    amount
            );
        }
        longCapsDeposit[fromToken][getCurrentStamp(longCapDuration)] += amount;
    }

    function _updateWithdrawCaps(address token, uint256 amount) internal {
        /// Short(default: per hour)
        if (
            shortCapsWithdraw[token][getCurrentStamp(shortCapDuration)] +
                amount >
            shortCaps[token]
        ) {
            revert ShortCapExceeded(
                shortCaps[token],
                shortCapsWithdraw[token][getCurrentStamp(shortCapDuration)] +
                    amount
            );
        }
        shortCapsWithdraw[token][getCurrentStamp(shortCapDuration)] += amount;

        /// Long(default: per day)
        if (
            longCapsWithdraw[token][getCurrentStamp(longCapDuration)] + amount >
            longCaps[token]
        ) {
            revert LongCapExceeded(
                longCaps[token],
                longCapsWithdraw[token][getCurrentStamp(longCapDuration)] +
                    amount
            );
        }
        longCapsWithdraw[token][getCurrentStamp(longCapDuration)] += amount;
    }

    function _setNotary(address notaryAddress) internal {
        if (notaryAddress == address(0x0)) revert NullAddress();

        emit NotaryChanged(notary, notaryAddress);
        notary = notaryAddress;
    }

    /*//////////////////////////
    ////// SET functions //////
    ////////////////////////*/

    function _setShortCap(address token, uint256 newValue) internal {
        if (token == address(0x0)) revert NullAddress();

        uint256 prevValue = shortCaps[token];
        emit ShortCapChanged(token, prevValue, newValue);
        shortCaps[token] = newValue;
    }

    function _setShortCapDuration(uint256 newValue) internal {
        emit ShortCapDurationChanged(shortCapDuration, newValue);
        shortCapDuration = newValue;
    }

    function _setLongCapDuration(uint256 newValue) internal {
        emit LongCapDurationChanged(longCapDuration, newValue);
        longCapDuration = newValue;
    }

    function _setLongCap(address token, uint256 newValue) internal {
        if (token == address(0x0)) {
            revert NullAddress();
        }
        emit LongCapChanged(token, longCaps[token], newValue);
        longCaps[token] = newValue;
    }

    function _setDefaultCrosschainThreshold() internal {
        shortCapDuration = 1 hours;
        longCapDuration = 1 days;
    }

    function _addBridge(address bridge, uint256 destinationChain) internal {
        if (bridge == address(0x0)) {
            revert NullAddress();
        }
        if (destinationChain == 0) {
            revert InvalidChain();
        }
        if (_bridgeAddressByChainId[destinationChain] != address(0x00)) {
            revert BridgeAlreadyAdded();
        }

        _bridgeAddressByChainId[destinationChain] = bridge;

        emit BridgeAdded(bridge, destinationChain);
    }

    function _removeBridge(uint256 destinationChain) internal {
        if (_bridgeAddressByChainId[destinationChain] == address(0x00)) {
            revert BridgeNotExist();
        }
        address bridge = _bridgeAddressByChainId[destinationChain];
        delete _bridgeAddressByChainId[destinationChain];

        emit BridgeRemoved(bridge, destinationChain);
    }

    function _addDestination(
        address fromToken,
        uint256 destinationChain,
        address toToken
    ) internal {
        if (_bridgeAddressByChainId[destinationChain] == address(0))
            revert UnknownDestinationChain();

        if (fromToken == address(0) || toToken == address(0))
            revert NullAddress();

        bytes32 direction = keccak256(
            abi.encodePacked(
                fromToken,
                block.chainid,
                _bridgeAddressByChainId[destinationChain],
                destinationChain
            )
        );

        if (_destinationTokens[direction] != address(0))
            revert DestinationAlreadyExists();

        _destinationTokens[direction] = toToken;

        emit DestinationAdded(fromToken, toToken, destinationChain);
    }

    function _removeDestination(
        address fromToken,
        uint256 destinationChain,
        address toToken
    ) internal {
        if (_bridgeAddressByChainId[destinationChain] == address(0))
            revert UnknownDestinationChain();

        bytes32 direction = keccak256(
            abi.encodePacked(
                fromToken,
                block.chainid,
                _bridgeAddressByChainId[destinationChain],
                destinationChain
            )
        );

        if (_destinationTokens[direction] != toToken)
            revert UnknownDestination();

        delete _destinationTokens[direction];

        emit DestinationRemoved(fromToken, toToken, destinationChain);
    }

    function _setXERC20Lockbox(address token, address lockbox) internal {
        if (address(token) == address(0) || address(lockbox) == address(0))
            revert NullAddress();

        if (xerc20TokenRegistry[token] != address(0))
            revert XERC20LockboxAlreadyAdded();

        emit XERC20LockboxAdded(token, lockbox);
        xerc20TokenRegistry[token] = lockbox;
    }

    function getCurrentStamp(uint256 duration) public view returns (uint256) {
        return (block.timestamp / duration) * duration;
    }
}
