// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface ILog {
    function addBlockId() external;
    function getBlockIdListCount() external view returns (uint256);
}

contract Referral is Initializable, OwnableUpgradeable {
    
    uint256 public constant TIME_OUT = 600;

    address public signer;
    address public logAddress;
    address public rootAddress;

    mapping(address => address) public referralMap;

    event UserReferral(uint256 referralId, address userAddress, address inviterAddress, uint256 time);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address _signer,
        address _logAddress,
        address _rootAddress
    ) public initializer {
        __Ownable_init(initialOwner);
        signer = _signer;
        logAddress = _logAddress;
        rootAddress = _rootAddress;
    }

    function setSigner(address _signer) external onlyOwner {
        signer = _signer;
    }

    function setReferral(address _userAddress, address _inviterAddress) external onlyOwner{
        require(referralMap[_userAddress]==address(0), "referral exist");
        require(_inviterAddress==rootAddress || referralMap[_inviterAddress]!=address(0), "inviterAddress error");
        referralMap[_userAddress] = _inviterAddress;

        uint256 referralId = ILog(logAddress).getBlockIdListCount();
        ILog(logAddress).addBlockId();

        emit UserReferral(referralId, _userAddress, _inviterAddress, block.timestamp);
    }
    
    function setReferral(address _userAddress, address _inviterAddress, uint256 _time, bytes memory _rsv ) external {
        
        require(msg.sender == _userAddress, "userAddress error");
        require(block.timestamp <= _time + TIME_OUT, "timeout");
        require(referralMap[_userAddress]==address(0), "referral exist");
        require(_inviterAddress==rootAddress || referralMap[_inviterAddress]!=address(0), "inviterAddress error");
        
        bytes32 hash = keccak256(abi.encode(address(this), _userAddress, _inviterAddress, _time));
        address signerTemp = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(hash), _rsv);
        require(signerTemp == signer, "signer error");
        
        referralMap[_userAddress] = _inviterAddress;

        uint256 referralId = ILog(logAddress).getBlockIdListCount();
        ILog(logAddress).addBlockId();

        emit UserReferral(referralId, _userAddress, _inviterAddress, block.timestamp);
    }
    
}
