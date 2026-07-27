// SPDX-License-Identifier: MIT
pragma solidity 0.5.11;
pragma experimental ABIEncoderV2;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Detailed} from "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";
import {CompoundStrategy} from "../src/strategies/CompoundStrategy.sol";

contract MockAsset is ERC20, ERC20Detailed {
    constructor() public ERC20Detailed("USD Coin", "USDC", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCToken {
    uint256 public exchangeRate = 2e18;

    function exchangeRateStored() external view returns (uint256) {
        return exchangeRate;
    }

    // Compound's redeem call returns an error code. Returning zero here
    // models the no-op redemption that leaves the strategy with no asset.
    function redeemUnderlying(uint256) external pure returns (uint256) {
        return 0;
    }

    function mint(uint256) external pure returns (uint256) {
        return 0;
    }

    function redeem(uint256) external pure returns (uint256) {
        return 0;
    }

    function balanceOfUnderlying(address) external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function supplyRatePerBlock() external pure returns (uint256) {
        return 0;
    }
}

contract PoC_18210 {
    function test_zeroCTokenRedemptionStillRunsAndReverts() public {
        MockAsset asset = new MockAsset();
        MockCToken cToken = new MockCToken();
        CompoundStrategy strategy = new CompoundStrategy();

        address[] memory assets = new address[](1);
        address[] memory pTokens = new address[](1);
        assets[0] = address(asset);
        pTokens[0] = address(cToken);

        // The test contract is both the strategy governor and vault caller.
        strategy.initialize(address(1), address(this), address(0), assets, pTokens);

        // At a 2e18 exchange rate, one wei of underlying rounds to zero
        // cTokens. The vulnerable parent nevertheless calls redeemUnderlying
        // and then attempts to transfer an asset the strategy does not hold.
        (bool succeeded, ) = address(strategy).call(
            abi.encodeWithSignature(
                "withdraw(address,address,uint256)", address(this), address(asset), uint256(1)
            )
        );
        require(!succeeded, "zero cToken redemption unexpectedly succeeded");
    }
}
