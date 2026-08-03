// SPDX-License-Identifier: MIT
/*
                                           +##*:                                          
                                         .######-                                         
                                        .########-                                        
                                        *#########.                                       
                                       :##########+                                       
                                       *###########.                                      
                                      :############=                                      
                   *###################################################.                  
                   :##################################################=                   
                    .################################################-                    
                     .*#############################################-                     
                       =##########################################*.                      
                        :########################################=                        
                          -####################################=                          
                            -################################+.                           
               =##########################################################*               
               .##########################################################-               
                .*#######################################################:                
                  =####################################################*.                 
                   .*#################################################-                   
                     -##############################################=                     
                       -##########################################=.                      
                         :+####################################*-                         
           *###################################################################:          
           =##################################################################*           
            :################################################################=            
              =############################################################*.             
               .*#########################################################-               
                 :*#####################################################-                 
                   .=################################################+:                   
                      -+##########################################*-.                     
     .+*****************###########################################################*:     
      +############################################################################*.     
       :##########################################################################=       
         -######################################################################+.        
           -##################################################################+.          
             -*#############################################################=             
               :=########################################################+:               
                  :=##################################################+-                  
                     .-+##########################################*=:                     
                         .:=*################################*+-.                         
                              .:-=+*##################*+=-:.                              
                                     .:=*#########+-.                                     
                                         .+####*:                                         
                                           .*#:    */
pragma solidity 0.8.18;

import {BaseProtocolProxy} from "../../base/BaseProtocolProxy.sol";
import {ICurve} from "../../interfaces/Curve/ICurve.sol";
import {ICurvePool} from "../../interfaces/Curve/ICurvePool.sol";

/**
 * @title Curve proxy contract
 * @author Pino development team
 * @notice Adds/Removes liquidity to Curve pools
 */
contract Curve is ICurve, BaseProtocolProxy {
    /**
     * @notice Receives permit2, and weth addresses
     * @param _permit2 Permit2 contract address
     * @param _weth Weth contract address
     */
    constructor(address _permit2, address _weth) payable BaseProtocolProxy(_permit2, _weth) {}

    /**
     * @notice Adds liquidity to a pool
     * @param _amounts Amounts of the tokens in the pool to deposit
     * @param _minMintAmount Minimum amount of LP tokens to mint from the deposit
     * @param _pool Address of the pool
     * @param _proxyFeeInWei Fee of the proxy contract
     */
    function deposit(uint256[2] calldata _amounts, uint256 _minMintAmount, ICurvePool _pool, uint256 _proxyFeeInWei)
        external
        payable
        nonETHReuse
    {
        _pool.add_liquidity{value: msg.value - _proxyFeeInWei}(_amounts, _minMintAmount);

        emit Deposit(msg.sender, address(_pool));
    }

    /**
     * @notice Withdraw token from the pool
     * @param _amount Quantity of LP tokens to burn in the withdrawal
     * @param _minAmounts Minimum amounts of underlying tokens to receive
     * @param _pool Address of the pool
     */
    function withdraw(uint256 _amount, uint256[2] calldata _minAmounts, ICurvePool _pool) external payable {
        _pool.remove_liquidity(_amount, _minAmounts);

        emit Withdraw(msg.sender, address(_pool));
    }

    /**
     * @notice Withdraw a single token from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _index Index value of the token to withdraw
     * @param _minAmount Minimum amount of token to receive
     * @param _pool Address of the pool
     * @return received Amount of token received
     */
    function withdrawOneCoinI(uint256 _amount, int128 _index, uint256 _minAmount, ICurvePool _pool)
        external
        payable
        returns (uint256 received)
    {
        uint256 balanceBefore = address(this).balance;

        // remove_liquidity_one_coin may transfer ETH or ERC20
        received = _pool.remove_liquidity_one_coin(_amount, _index, _minAmount);

        uint256 balanceAfter = address(this).balance;

        if (balanceAfter > balanceBefore) {
            // Calculate the ETH received and wrap it to WETH
            weth.deposit{value: balanceAfter - balanceBefore}();
        }

        emit Withdraw(msg.sender, address(_pool));
    }

    /**
     * @notice Withdraw a single token from the pool
     * @param _amount Amount of LP tokens to burn in the withdrawal
     * @param _index Index value of the coin to withdraw
     * @param _minAmount Minimum amount of coin to receive
     * @param _pool Address of the pool
     * @return received Amount of token received
     */
    function withdrawOneCoinU(uint256 _amount, uint256 _index, uint256 _minAmount, ICurvePool _pool)
        external
        payable
        returns (uint256 received)
    {
        uint256 balanceBefore = address(this).balance;

        // remove_liquidity_one_coin may transfer ETH or ERC20
        received = _pool.remove_liquidity_one_coin(_amount, _index, _minAmount);

        uint256 balanceAfter = address(this).balance;

        if (balanceAfter > balanceBefore) {
            // Calculate the ETH received and wrap it to WETH
            weth.deposit{value: balanceAfter - balanceBefore}();
        }

        emit Withdraw(msg.sender, address(_pool));
    }
}
