// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "./PErc721Delegate.sol";
import "../../Interfaces/LPInterfaces.sol";
import "../../Interfaces/AlgebraV1Interfaces.sol";
import "./../../PriceOracle/Impl/UniV3PriceOracle.sol";

interface IAggregatorOracle {
    function uniV3PriceOracle() external view returns (NFPOracle);
    function camelotV2Oracle() external view returns (NFPOracle);
}

/**
 * @title Paribus PErc721NFPDelegate Contract
 * @notice PErc721Tokens which wrap an EIP-721 underlying and are delegated to
 * @author Paribus
 */
contract PNFPDelegate is PErc721Delegate {

    mapping(address=>bool) public whitelistedPools;

    function setWhitelistedPool(address poolAddress, bool isWhitelisted) external {
        require(msg.sender == admin, "only admin");
        setWhitelistedPoolInternal(poolAddress, isWhitelisted);
    }

    function setWhitelistedPoolInternal(address poolAddress, bool isWhitelisted) internal {    
        whitelistedPools[poolAddress] = isWhitelisted;
        emit WhitelistedPool(poolAddress, isWhitelisted);
    }

    function mint(uint tokenId) external returns (Error) {
        
        if(whitelistedPools[this.getPool(tokenId)])
            return mintInternal(msg.sender, tokenId);
        else 
            return Error.NON_WHITE_LISTED_POOL;
    } 

    ///@dev PErc721NFPDelegate will be deployed for NFP markets, 
    ///@notice  underlying NFT will always be sent to liquidator can not exchange LP positions 
    function liquidateCollateral(address, uint, address) external  returns (Error) {
        revert("PErc721NFPDelegate: only seize allowed");
    }

    function getPool(uint tokenId) external view returns(address);

}