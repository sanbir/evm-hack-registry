pragma solidity ^0.5.17;
pragma experimental ABIEncoderV2;

import "./PNFPDelegate.sol";

contract PNFPCamelotDelegate is PNFPDelegate {
    
    /**
     * @notice Called by the delegator on a delegate to initialize it for duty. Should not be marked as pure
     * @param data The encoded bytes data for any initialization
     */
    function _becomeImplementation(bytes calldata data) external {
        require(msg.sender == admin, "only admin");
        // data may contain brrowable (default true) to be false for LP token markets
        if (data.length == 0) revert('invalid pool address');
        else {
            address poolAddress = abi.decode(data, (address));
            require (poolAddress != address(0), "invalid number of pools");
            setWhitelistedPoolInternal(poolAddress, true);
        }
    }

    function getPool(uint tokenId) external view returns(address) {
        NFPOracle uniV3Oracle = IAggregatorOracle(comptroller.oracle()).camelotV2Oracle();
        return uniV3Oracle.getPool(tokenId);
    }
}