// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ICREATE2Factory {
    event ContractCreated(address indexed addr);

    function deployCreate2(
        bytes calldata creationCode
    ) external returns (address);
}

interface ICREATE3Factory {
    /**
     * @notice Emitted when a new XERC20 is deployed
     * @param _xerc20 The address of the xerc20
     */
    event XERC20Deployed(address _xerc20);

    /**
     * @notice Emitted when a new XERC20Lockbox is deployed
     * @param _lockbox The address of the lockbox
     */
    event LockboxDeployed(address _lockbox);

    /**
     * @notice Reverts when a non-owner attempts to call
     */
    error IXERC20Factory_NotOwner();

    /**
     * @notice Reverts when a lockbox is trying to be deployed from a malicious address
     */
    error IXERC20Factory_BadTokenAddress();

    /**
     * @notice Reverts when a lockbox is already deployed
     */
    error IXERC20Factory_LockboxAlreadyDeployed();

    /**
     * @notice Reverts when a the length of arrays sent is incorrect
     */
    error IXERC20Factory_InvalidLength();

    function deployXERC20(
        string memory _name,
        string memory _symbol
    ) external returns (address _xerc20);

    function deployLockbox(
        address _xerc20,
        address _baseToken,
        bool _isNative
    ) external returns (address _lockbox);
}

interface IFactory is ICREATE2Factory, ICREATE3Factory {}
