// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";

/*
 * @title a contract which implements EIP-1167 minimal proxy pattern and adds role based access control
 * @notice grants DEFAULT_ADMIN_ROLE when deploying the implementation contract and after cloning a new instance
 */
contract Clonable is AccessControl {
	bool private initializedRoleBasedAccessControl;

	event Cloned(address newInstance);

	error AlreadyInitializedRBAC();

	/*
	 * @notice marked the constructor function as payable, because it costs less gas to execute,
	 * since the compiler does not have to add extra checks to ensure that a payment wasn't provided.
	 * A constructor can safely be marked as payable, since only the deployer would be able to pass funds,
	 * and the project itself would not pass any funds.
	 */
	constructor() payable {
		setDefaultAdmin(msg.sender);
	}

	/*
	 * @notice clones a new instance of this contract and grant default admin roler to given defaultAdmin
	 */
	function clone(address defaultAdmin) public returns (address newInstance) {
		// Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
		bytes20 addressBytes = bytes20(address(this));
		assembly {
			// EIP-1167 bytecode
			let clone_code := mload(0x40)
			mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
			mstore(add(clone_code, 0x14), addressBytes)
			mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
			newInstance := create(0, clone_code, 0x37)
		}
		emit Cloned(newInstance);
		Clonable(newInstance).setDefaultAdmin(defaultAdmin);
	}

	/*
	 * @notice clones a new instance of this contract and grant default admin roler to caller
	 */
	function getClone() external returns (address) {
		return clone(msg.sender);
	}

	/*
	 * @dev initializes DEFAULT_ADMIN_ROLE (can be initialized only once)
	 * @notice this function does emit a RoleGranted event in AccessControl._grantRole
	 */
	function setDefaultAdmin(address initialAdmin) public {
		if (initializedRoleBasedAccessControl) revert AlreadyInitializedRBAC();
		_grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
		initializedRoleBasedAccessControl = true;
	}
}
