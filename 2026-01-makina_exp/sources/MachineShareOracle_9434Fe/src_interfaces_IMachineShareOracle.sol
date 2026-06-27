// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IMachineShareOracle {
    error InvalidShareOwner();

    event ShareOwnerMigrated(address indexed oldShareOwner, address indexed newShareOwner);

    /// @notice Initializer of the contract.
    /// @param _shareOwner The current owner contract of the share (machine or pre-deposit vault).
    /// @param _decimals Decimals to use for the oracle price.
    function initialize(address _shareOwner, uint8 _decimals) external;

    /// @notice Decimals of the oracle.
    function decimals() external view returns (uint8);

    /// @notice Description of the oracle.
    function description() external view returns (string memory);

    /// @notice Address of the share owner (machine or pre-deposit vault).
    function shareOwner() external view returns (address);

    /// @notice Returns the price of one machine share token expressed in machine accounting tokens
    /// @dev The price is expressed with `decimals` precision.
    /// @return sharePrice The price of one machine share token expressed in machine accounting tokens, scaled to `decimals` precision.
    function getSharePrice() external view returns (uint256 sharePrice);

    /// @notice Notifies the migration of the original share owner from a pre-deposit vault to a machine.
    /// @dev Can only be called once and only if the share owner was initially a pre-deposit vault.
    /// @dev This function can be call permissionlessly and allows to optimize gas costs for users of the oracle.
    function notifyPdvMigration() external;
}
