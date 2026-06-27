// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.5.17;

import "../../PToken/PErc20/PErc20.sol";
import "../../Interfaces/ParibusOracleInterface.sol";
import "../PriceOracleInterfaces.sol";
import "openzeppelin2/math/SafeMath.sol";
import "openzeppelin2/token/ERC20/ERC20Detailed.sol";
interface DataFeedInterface {
    struct DataFeed{
        address addr;
        uint heartbeat;
    }
}
contract BaseSourceOracle is ISourceOracle {
    using SafeMath for uint;

    /**
      * @notice Adjusts the decimals of a value
      * @param valueDecimals The current decimals of the value
      * @param wantedDecimals The desired decimals for the value
      * @param value The value to be adjusted
      * @return uint The value adjusted to the desired decimals
      */
    function adjustDecimals(uint valueDecimals, uint wantedDecimals, uint value) internal pure returns (uint) {
        if (wantedDecimals >= valueDecimals) return value.mul(10 ** wantedDecimals.sub(valueDecimals));
        else return value.div(10 ** valueDecimals.sub(wantedDecimals));
    }

    /**
      * @notice Computes the absolute difference between two numbers.
      * @param a The first number.
      * @param b The second number.
      * @return The absolute difference between a and b.
    */
    function subabs(uint a, uint b) internal pure returns (uint) {
        return a > b ? a - b : b - a;
    }
}

contract Oracle is IOracle {

    /// @notice The address of pEther. We need this because pEther has no .underlying() property for obvious reason
    address public pEtherAddress;

    /**
      * @notice Get the decimals and address of a given pToken's underlying asset
      * @param pToken The token
      * @return (decimals of underlying, address of underlying (address(0) for pEther))
      */
    function getUnderlyingDecimalsAndAddress(PToken pToken) public view returns (uint, address) {
        if (address(pToken) == pEtherAddress) return (18, address(0));
        else {
            PErc20 pErc20 = PErc20(address(pToken));
            return (ERC20Detailed(pErc20.underlying()).decimals(), pErc20.underlying());
        }
    }

    function getUnderlyingPrice(PToken pToken) public view returns (uint) {
        (uint underlyingDecimals, address underlyingAddress) = getUnderlyingDecimalsAndAddress(pToken);
        return getPriceOfUnderlying(underlyingAddress, SafeMath.sub(36, underlyingDecimals));
    }
}


/// @dev This contract integrates ParibusOracle with Paribus protocol interface
contract OracleNFT is IOracleNFT {
    address public paribusOracle;

    function getUnderlyingNFTPrice(PNFTToken pNFTToken, uint tokenId) public view returns (uint) {
        (uint priceWei, uint updatedAt) = ParibusOracleInterface_(paribusOracle).getTokenPriceWei(pNFTToken.underlying(), tokenId);
        require(updatedAt + ParibusOracleInterface_(paribusOracle).heartbeat() > block.timestamp, "invalid ParibusOracle answer: updatedAt");
        require(priceWei > 0, "invalid ParibusOracle answer: priceWei");

        // return price in usd
        return (priceWei * getETHPrice()) / 1e18;
    }

    /// @dev returns 0 if price not available
    function getOrRequestUnderlyingNFTPrice(PNFTToken pNFTToken, uint tokenId) public returns (uint) {
        (uint priceWei, uint updatedAt) = ParibusOracleInterface_(paribusOracle).getOrRequestTokenPriceWei(pNFTToken.underlying(), tokenId);

        if (updatedAt + ParibusOracleInterface_(paribusOracle).heartbeat() < block.timestamp) {
            // cant revert here
            return 0;
        }

        // return price in usd
        return (priceWei * getETHPrice()) / 1e18;
    }
}