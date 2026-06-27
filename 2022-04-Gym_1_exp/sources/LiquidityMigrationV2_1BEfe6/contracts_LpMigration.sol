// SPDX-License-Identifier: MIT

pragma solidity ^0.8.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRouter {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
}

contract LiquidityMigrationV2 is Context, Ownable, ReentrancyGuard {
  using SafeMath for uint256;

  address public v1Address = 0xE98D920370d87617eb11476B41BF4BE4C556F3f8;
  address public v2Address = 0x3a0d9d7764FAE860A659eb96A500F1323b411e68;
  address public lpAddress = 0x8dC058bA568f7D992c60DE3427e7d6FC014491dB;
  address public router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

  IRouter private Router;

  event migration(uint256 LPspended, uint256 LPrecived);

  constructor () {
      Router = IRouter(router);
      IERC20(lpAddress).approve(address(Router), type(uint256).max);
      IERC20(v2Address).approve(address(Router), type(uint256).max);
  }
  
  function migrate(uint256 _lpTokens) public nonReentrant {
      require(_lpTokens > 0, "zero LP tokens sended");
      require(IERC20(lpAddress).transferFrom(_msgSender(), address(this), _lpTokens), "transfer failed");
      (uint256 amountTokenRecived, 
       uint256 amountEthRecived) = Router.removeLiquidityETH(
          v1Address,
          _lpTokens,
          0, 
          0, 
          address(this), 
          block.timestamp);
      
      (uint256 amountTokenStaked,
       uint256 amountEthStaked,
       uint256 LpStaked) = Router.addLiquidityETH{value:amountEthRecived}(
          v2Address, 
          amountTokenRecived, 
          0, 
          0, 
          _msgSender(), 
          block.timestamp);

      uint256 diffEth = amountEthRecived - amountEthStaked;
      if (diffEth > 0) {
        payable(_msgSender()).transfer(diffEth);
      }
        
      emit migration(_lpTokens, LpStaked);
  }
  
  function withdraw() external onlyOwner {
    uint256 balance = address(this).balance;
    payable(owner()).transfer(balance);
  }

  function withdrawTokens() external onlyOwner {
    uint256 balance = IERC20(v2Address).balanceOf(address(this));
    IERC20(v2Address).transfer(owner(), balance);
  }
  
  fallback() external virtual {}
  receive() external payable virtual {}
}