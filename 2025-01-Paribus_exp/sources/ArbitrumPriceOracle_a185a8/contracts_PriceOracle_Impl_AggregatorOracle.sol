// SPDX-License-Identifier: MIT
pragma solidity ^0.5.17;
import "./SourceOracle.sol";
import "./UniV2PriceOracle.sol";
import "./UniV3PriceOracle.sol";
import "./AlgebraV1PriceOracle.sol";
import "./Api3PriceOracle.sol";
import "./ChainlinkPriceOracle.sol";
import "../../Interfaces/IAlgebraSingleAssetOracle.sol";

// contract aggrigates multiple source price oracles along with NFT oracle
contract AggregatorOracle is Oracle, OracleNFT, ISourceOracle {
    enum V3Dex { Camelot, UniV3}

    /// @notice Administrator for this contract
    address public admin;

    /// @notice Pending administrator for this contract
    address public pendingAdmin;

    // all oracle sources
    Api3PriceOracle public api3SourceOracle;
    ChainlinkPriceOracle public chainlinkSourceOracle;
    UniV2PriceOracle public uniV2SourceOracle;
    IAlgebraSingleAssetOracle public algebraTwapSourceOracle;

    NFPOracle public uniV3PriceOracle;
    NFPOracle public camelotV2Oracle;

    modifier onlyOwner() {
        require(msg.sender == admin, "AggregatorOracle: admin only");
        _;
    }

    /// @notice Emitted when pendingAdmin is changed
    event NewPendingAdmin(address oldPendingAdmin, address newPendingAdmin);

    /// @notice Emitted when pendingAdmin is accepted, which means admin is updated
    event NewAdmin(address oldAdmin, address newAdmin);

    // Initializes the contract setting the deployer as the initial admin.
    constructor() public {
        admin = msg.sender;
    }

    /**
      * @notice Checks if the underlying token of the given PToken is supported by any of the source oracles.
      * @param pToken The PToken to check for support.
      * @return True if the underlying token is supported, false otherwise.
      */
    function isPTokenSupported(PToken pToken) public view returns (bool) {
        // check if underlying token is supported by any of the source oracles
        return isTokenSupported(PErc20(address(pToken)).underlying());
    }

    /**
      * @notice Checks if the given token is supported by any of the source oracles.
      * @param token The token to check for support.
      * @return True if the token is supported, false otherwise.
      */
    function isTokenSupported(address token) public view returns (bool) {
        if (address(chainlinkSourceOracle) != address(0) && chainlinkSourceOracle.isTokenSupported(token)) return true;
        if (address(api3SourceOracle) != address(0) && api3SourceOracle.isTokenSupported(token)) return true;
        if (address(uniV2SourceOracle) != address(0) && uniV2SourceOracle.isTokenSupported(token)) return true;
        if (address(algebraTwapSourceOracle) != address(0) && algebraTwapSourceOracle.isTokenSupported(token)) return true;

        return false;
    }

    /**
      * @notice Gets the price of the underlying token with the specified decimals.
      * @param token The address of the token.
      * @param decimals The number of decimals for the token.
      * @return The price of the underlying token.
      */
    function getPriceOfUnderlying(address token, uint decimals) public view returns (uint) {
        return getTokenPrice(token, decimals);
    }

    /**
      * @notice Gets the price of the given token with the specified decimals from the first supporting source oracle.
      * @param token The address of the token.
      * @param decimals The number of decimals for the token.
      * @return The price of the token.
      */
    function getTokenPrice(address token, uint decimals) public view returns (uint) {
        // get token price from the first source oracle that supports the token
        if (address(chainlinkSourceOracle) != address(0) && chainlinkSourceOracle.isTokenSupported(token)) return chainlinkSourceOracle.getTokenPrice(token, decimals);
        else if (address(api3SourceOracle) != address(0) && api3SourceOracle.isTokenSupported(token)) return api3SourceOracle.getTokenPrice(token, decimals);
        else if (address(uniV2SourceOracle) != address(0) && uniV2SourceOracle.isTokenSupported(token)) return uniV2SourceOracle.getTokenPrice(token, decimals);
        else if (address(algebraTwapSourceOracle) != address(0) && algebraTwapSourceOracle.isTokenSupported(token)) return algebraTwapSourceOracle.getTokenPrice(token, decimals);

        revert("token not supported");
    }

    /**
      * @notice Gets the price of the underlying NFT from the specified oracle.
      * @param pNFTToken The PNFTToken containing the underlying NFT.
      * @param tokenId The ID of the NFT.
      * @return The price of the underlying NFT.
      */
    function getUnderlyingNFTPrice(PNFTToken pNFTToken, uint tokenId) public view returns (uint) {
        if (address(uniV3PriceOracle) != address(0) && address(uniV3PriceOracle.nfpManager()) == pNFTToken.underlying())
            return uniV3PriceOracle.getPositionPrice(tokenId);
        else if (address(camelotV2Oracle) != address(0) && address(camelotV2Oracle.nfpManager()) == pNFTToken.underlying())
            return camelotV2Oracle.getPositionPrice(tokenId);
        else
            return OracleNFT.getUnderlyingNFTPrice(pNFTToken, tokenId);
    }

    /**
      * @notice Gets the price of ETH.
      * @dev The data source for ETH price must be provided for this (like Chainlink).
      * @return The price of ETH.
      */
    function getETHPrice() internal view returns (uint) {
        return getPriceOfUnderlying(address(0), 18);
    }

    /**
      * @notice Begins transfer of admin rights. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @dev Admin function to begin change of admin. The newPendingAdmin must call `_acceptAdmin` to finalize the transfer.
      * @param newPendingAdmin New pending admin.
      */
    function _setPendingAdmin(address newPendingAdmin) external {
        require(msg.sender == admin, "AggregatorOracle::_setPendingAdmin: admin only");
        require(newPendingAdmin != address(0), "AggregatorOracle::_setPendingAdmin: admin cannot be zero address");

        emit NewPendingAdmin(pendingAdmin, newPendingAdmin);
        pendingAdmin = newPendingAdmin;
    }

    /**
      * @notice Accepts transfer of admin rights. msg.sender must be pendingAdmin
      * @dev Admin function for pending admin to accept role and update admin
      */
    function _acceptAdmin() external {
        require(msg.sender == pendingAdmin, "AggregatorOracle::_acceptAdmin: pending admin only");

        emit NewAdmin(admin, pendingAdmin);
        emit NewPendingAdmin(pendingAdmin, address(0));
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    
    /// @dev as Aggregator will always deploy UniV2PriceOracle in constructor 
    /// it will always be owner and we can activate new pairs by calling this function
    function setUniV2SupportedPair(address pair) external onlyOwner {   
        // aggregator oracle should always be owner for UniV2PriceOracle
        require(isTokenSupported(LPTokenInterface(pair).token0()) && isTokenSupported(LPTokenInterface(pair).token1()), "token0 or token1 not supported");
        uniV2SourceOracle.setSupportedPair(pair);
    }

    /// @dev as Aggregator will always deploy UniV2PriceOracle in constructor 
    /// it will always be owner and we can activate new pairs by calling this function
    function setV3SupportedPair(address pair, V3Dex dex) external onlyOwner {   
        // aggregator oracle should always be owner for UniV2PriceOracle
        if (dex == V3Dex.UniV3) {
            require(isTokenSupported(IUniswapV3Pool(pair).token0()) && isTokenSupported(IUniswapV3Pool(pair).token1()), "token0 or token1 not supported");
            uniV3PriceOracle.setSupportedPair(pair);
        }
        else if (dex == V3Dex.Camelot) {
            require(isTokenSupported(IAlgebraV1Pool(pair).token0()) && isTokenSupported(IAlgebraV1Pool(pair).token1()), "token0 or token1 not supported");
            camelotV2Oracle.setSupportedPair(pair);
        }
    }
    
    /**
      * @notice Adds an Chainlink data feed to the oracle.
      * @param token The address of the token.
      * @param feed contract address of the Chainlink data feed.
      * @param heartbeat The heartbeat interval for the feed.
      */
    function setSupportedChainlinkFeed(address token, address feed, uint heartbeat) external onlyOwner {
        require(!isTokenSupported(token), "AggregatorOracle: token already supported");
        chainlinkSourceOracle.addChainlinkFeed(token, feed, heartbeat);
    }
    
   /**
      * @notice Adds an API3 data feed to the oracle.
      * @param token The address of the token.
      * @param feedProxy The address of the API3 data feed proxy.
      */
    function setSupportedApi3Feed(address token, address feedProxy, uint heartbeat) external onlyOwner {
        require(!isTokenSupported(token), "AggregatorOracle: token already supported");
        api3SourceOracle.addApi3Feed(token, feedProxy, heartbeat);
    }

    function setNewAlgebraSingleAssetOracle(address _newAlgebraSingleAssetOracle) external onlyOwner {
        require(_newAlgebraSingleAssetOracle != address(0), "AggregatorOracle: zero address not allowed");
        algebraTwapSourceOracle = IAlgebraSingleAssetOracle(_newAlgebraSingleAssetOracle);
    }

}