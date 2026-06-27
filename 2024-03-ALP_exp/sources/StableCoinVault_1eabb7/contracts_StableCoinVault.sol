// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./vaults/apolloX/ApolloXBscVault.sol";
import "./BasePortfolioV2.sol";

contract StableCoinVault is BasePortfolioV2 {
  using SafeERC20 for IERC20;

  function initialize(
    string memory name_,
    string memory symbol_,
    address apolloXBscVaultAddr
  ) public initializer {
    BasePortfolioV2._initialize(name_, symbol_);

    require(
      apolloXBscVaultAddr != address(0),
      "apolloXBscVaultAddr cannot be zero"
    );

    vaults = [AbstractVaultV2(ApolloXBscVault(apolloXBscVaultAddr))];
  }
}
