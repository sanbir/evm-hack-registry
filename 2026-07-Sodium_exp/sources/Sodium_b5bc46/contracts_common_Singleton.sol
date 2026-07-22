// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

import "./SelfAuthorized.sol";

contract Singleton is SelfAuthorized {
    // singleton always needs to be first declared variable, to ensure that it is at the same location as in the Proxy contract.
    // It should also always be ensured that the address is stored alone (uses a full word)
    // @deprecated
    address private _singleton;

    /**
     * @notice Updates the Wallet implementation
     * @param _imp New implementation address
     * @dev The wallet implementation is stored on the storage slot
     *   defined by the address of the wallet itself
     *   WARNING updating this value may break the wallet and users
     *   must be confident that the new implementation is safe.
     */
    function _setSingleton(address _imp) internal {
        assembly {
            sstore(address(), _imp)
        }
    }

    /**
     * @notice Returns the Wallet implementation
     * @return _imp The address of the current Wallet implementation
     */
    function getSingleton() external view returns (address _imp) {
        assembly {
            _imp := sload(address())
        }
    }

    function isSodiumSingleton() external pure returns (bool) {
        return true;
    }
}
