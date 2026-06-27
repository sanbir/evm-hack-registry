// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";
import "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";

import "./Configurable.sol";
import "./Recoverable.sol";
import "./interfaces/INonfungiblePositionManager.sol";

contract Locker is Configurable, Recoverable, IERC721Receiver {
    using SafeERC20 for IERC20;

    struct Lock {
        address token;
        uint256 tokenId; /// @dev 0 for ERC20
        address beneficiary;
        uint256 amount; /// @dev 0 for NFT
        uint256 unlockTime;
        bool withdrawn;
    }

    uint256 public lockId;
    mapping (uint256 => Lock) public locks;

    event LockCreated(uint256 indexed _id, address indexed _beneficiary, address indexed _token, uint256 _tokenId, uint256 _amount, uint256 _unlockTime);
    event LockWithdrawn(uint256 indexed _id);
    event LockExtended(uint256 indexed _id, uint256 _oldUnlockTime, uint256 _newUnlockTime);
    event LockTransferred(uint256 indexed _id, address indexed _oldBeneficiary, address _newBeneficiary);
    event LockSplit(uint256 indexed _id, uint256 indexed _splitId);
    event LPFeesCollected(uint256 indexed _id, uint256 indexed _amount0, uint256 _amount1);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _config) external initializer {
        __Configurable_init(_config, IConfig.Tools.Locker);
        __Recoverable_init();
    }

    /// TODO: Think about referrer functionality in V2
    function createLock(address _token, uint256 _tokenId, address _beneficiary, uint256 _amount, uint256 _unlockTime) external payable whenNotPaused returns (uint256 _id) {
        require(address(_token) != address(0), "Locker: token address is zero");
        require(address(_beneficiary) != address(0), "Locker: beneficiary address is zero");
        require(_unlockTime > block.timestamp, "Locker: unlock time must be in the future");
        if (_isNFT(_token)) {
            require(_amount == 0, "Locker: NFT amount must be zero");
            IERC721(_token).safeTransferFrom(_msgSender(), address(this), _tokenId);
        } else {
            require(_tokenId == 0, "Locker: invalid token ID");
            require(_amount > 0, "Locker: token amount must be greater than zero");
            IERC20(_token).safeTransferFrom(_msgSender(), address(this), _amount);
        }
        address[] memory _whitelist = new address[](2);
        _whitelist[0] = _token;
        _whitelist[1] = _beneficiary;
        _feeHandler(_whitelist);
        _id = lockId;
        ++lockId;
        locks[_id] = Lock({
            token: _token,
            tokenId: _tokenId,
            beneficiary: _beneficiary,
            amount: _amount,
            unlockTime: _unlockTime,
            withdrawn: false
        });
        emit LockCreated(_id, _beneficiary, _token, _tokenId, _amount, _unlockTime);
    }

    function withdrawLock(uint256 _id) external whenNotPaused {
        Lock storage _lock = locks[_id];
        require(!_lock.withdrawn, "Locker: lock already withdrawn");
        require(block.timestamp >= _lock.unlockTime, "Locker: lock not yet unlocked");
        require(_msgSender() == _lock.beneficiary, "Locker: not the beneficiary");
        _lock.withdrawn = true; /// @dev Prevents reentrancy
        if (_isNFT(_lock.token)) {
            IERC721(_lock.token).safeTransferFrom(address(this), _lock.beneficiary, _lock.tokenId);
        } else {
            IERC20(_lock.token).safeTransfer(_lock.beneficiary, _lock.amount);
        }
        emit LockWithdrawn(_id);
    }

    function extendLock(uint256 _id, uint256 _newUnlockTime) external whenNotPaused {
        Lock storage _lock = locks[_id];
        require(!_lock.withdrawn, "Locker: lock already withdrawn");
        require(_newUnlockTime > _lock.unlockTime, "Locker: new unlock time must be in the future");
        require(_msgSender() == _lock.beneficiary, "Locker: not the beneficiary");
        uint256 _oldUnlockTime = _lock.unlockTime;
        _lock.unlockTime = _newUnlockTime;
        emit LockExtended(_id, _oldUnlockTime, _newUnlockTime);
    }

    function transferLock(uint256 _id, address _newBeneficiary) external whenNotPaused {
        Lock storage _lock = locks[_id];
        require(!_lock.withdrawn, "Locker: lock already withdrawn");
        require(_msgSender() == _lock.beneficiary, "Locker: not the beneficiary");
        require(_newBeneficiary != address(0), "Locker: new beneficiary address is zero");
        _lock.beneficiary = _newBeneficiary;
        emit LockTransferred(_id, _msgSender(), _newBeneficiary);
    }

    function splitLock(uint256 _id, uint256 _newAmount, uint256 _newUnlockTime) external payable whenNotPaused returns (uint256 _splitId) {
        Lock storage _lock = locks[_id];
        require(!_lock.withdrawn, "Locker: lock already withdrawn");
        require(_newUnlockTime >= _lock.unlockTime, "Locker: new unlock time must be greater than or equal to the current lock time");
        require(_newAmount > 0 && _newAmount < _lock.amount, "Locker: invalid new amount");
        require(!_isNFT(_lock.token), "Locker: NFTs cannot be split");
        address[] memory _whitelist = new address[](2);
        _whitelist[0] = _lock.token;
        _whitelist[1] = _lock.beneficiary;
        _feeHandler(_whitelist);
        _lock.amount -= _newAmount;
        _splitId = lockId;
        ++lockId;
        locks[_splitId] = Lock({
            token: _lock.token,
            tokenId: 0,
            beneficiary: _lock.beneficiary,
            amount: _newAmount,
            unlockTime: _newUnlockTime,
            withdrawn: false
        });
        emit LockSplit(_id, _splitId);
    }

    function collectLPFees(uint256 _id) external whenNotPaused {
        Lock storage _lock = locks[_id];
        require(!_lock.withdrawn, "Locker: lock already withdrawn");
        require(_isNFT(_lock.token), "Locker: not an NFT");
        require(_msgSender() == _lock.beneficiary, "Locker: not the beneficiary");
        INonfungiblePositionManager _manager = INonfungiblePositionManager(_lock.token);
        INonfungiblePositionManager.CollectParams memory _params = INonfungiblePositionManager.CollectParams({
            tokenId: _lock.tokenId,
            recipient: _lock.beneficiary,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        try _manager.collect(_params) returns (uint256 _amount0, uint256 _amount1) {
            emit LPFeesCollected(_id, _amount0, _amount1);
        } catch {
            revert("Locker: LP fee collection unsupported");
        }
    }

    function _feeHandler(address[] memory _whitelist) internal {
        uint256 _f = _fee(_whitelist);
        if (_f > 0) {
            (bool _success, ) = config.treasury().call{value: _f}("");
            require(_success, "Locker: fee transfer failed");
        }
        if (msg.value > _f) {
            (bool _success, ) = payable(_msgSender()).call{value: msg.value - _f}("");
            require(_success, "Locker: refund failed");
        }
    }

    function _isNFT(address _token) internal view returns (bool) {
        (bool _success, bytes memory _result) = _token.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, type(IERC721).interfaceId));
        if (_success && _result.length >= 32) {
            return abi.decode(_result, (bool));
        }
        return false;
    }

    fallback() external {
        revert("Locker: ETH transfers not allowed");
    }

    function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _authorizeUpgrade(address _newImplementation) internal onlyOwner override {}
}
