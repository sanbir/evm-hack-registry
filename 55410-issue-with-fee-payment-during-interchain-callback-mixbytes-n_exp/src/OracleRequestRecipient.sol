// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IMessageRecipient} from "./interfaces/IMessageRecipient.sol";
import {IOracleTrigger} from "./interfaces/IOracleTrigger.sol";
import {TypeCasts} from "./libs/TypeCasts.sol";

import {IInterchainSecurityModule, ISpecifiesInterchainSecurityModule} from "./interfaces/IInterchainSecurityModule.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

using TypeCasts for address;

/**
 * @title OracleRequestRecipient
 * @notice This contract receives and processes oracle request messages from an interchain network. Whitelisted in Hyperlane
 * @dev Implements security measures and enforces valid sender verification.
 */
contract OracleRequestRecipient is
    Ownable,
    IMessageRecipient,
    ISpecifiesInterchainSecurityModule,
    ReentrancyGuard
{
    /// @notice Address of the interchain security module (ISM)
    IInterchainSecurityModule public interchainSecurityModule;

    /// @notice Address of the whitelisted RequestOracle
    mapping(uint32 => mapping(bytes32 => bool)) public whitelistedSenders;





    /// @notice Address of the Oracle Trigger contract
    address public oracleTriggerAddress;

    /// @notice Emitted when a valid oracle request update is received
    /// @param caller The address that sent the request
    /// @param key The decoded key from the request data
    event ReceivedCall(address indexed caller, string key);

    /**
     * @notice Handles incoming oracle requests from the interchain network.
     * @dev Ensures only authorized senders can invoke this function and prevents reentrancy attacks.
     * @param _origin The source chain ID from where the request originated
     * @param _sender The sender address in bytes32 format
     * @param _data Encoded payload containing the oracle request key
     */
    function handle(
        uint32 _origin,
        bytes32 _sender,
        bytes calldata _data
    ) external payable virtual override nonReentrant {
        require(_data.length > 0, "Invalid data length");
        require(
            oracleTriggerAddress != address(0),
            "Oracle trigger address not set"
        );
        require(whitelistedSenders[_origin][_sender], "Sender not whitelisted for this origin");

        address sender = address(uint160(uint256(_sender)));

        //TODO sender should be whitelisted RequestOracle

        require(
            msg.sender == IOracleTrigger(oracleTriggerAddress).getMailBox(),
            "Unauthorized caller"
        );

        string memory key = abi.decode(_data, (string));

        emit ReceivedCall(sender, key);

        IOracleTrigger(oracleTriggerAddress).dispatch(_origin, sender, key);
    }


     function addToWhitelist(uint32 _origin, bytes32 _sender) onlyOwner external {
        whitelistedSenders[_origin][_sender] = true;
     }

    function removeFromWhitelist(uint32 _origin, bytes32 _sender) onlyOwner external {
        whitelistedSenders[_origin][_sender] = false;
     }

    /**
     * @notice Sets the interchain security module (ISM) address.
     * @dev Can only be called by the contract owner.
     * @param _ism Address of the new ISM contract
     */
    function setInterchainSecurityModule(address _ism) external onlyOwner {
        require(_ism != address(0), "Invalid ISM address");

        interchainSecurityModule = IInterchainSecurityModule(_ism);
    }

    /**
     * @notice Sets the Oracle Trigger contract address.
     * @dev Can only be called by the contract owner.
     * @param _oracleTrigger Address of the new Oracle Trigger contract
     */
    function setOracleTriggerAddress(
        address _oracleTrigger
    ) external onlyOwner {
        require(_oracleTrigger != address(0), "Invalid oracle trigger address");

        oracleTriggerAddress = _oracleTrigger;
    }

    /**
     * @notice Prevents direct ETH transfers to the contract.
     */
    receive() external payable {
        revert("Direct ETH transfers not allowed");
    }

    /**
     * @notice Retrieves the current interchain security module address.
     * @return Address of the ISM contract
     */
    function getInterchainSecurityModule() external view returns (address) {
        return address(interchainSecurityModule);
    }

    /**
     * @notice Retrieves the current Oracle Trigger contract address.
     * @return Address of the Oracle Trigger contract
     */

    function getOracleTriggerAddress() external view returns (address) {
        return oracleTriggerAddress;
    }
}
