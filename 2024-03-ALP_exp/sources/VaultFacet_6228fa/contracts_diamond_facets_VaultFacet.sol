// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../utils/Bits.sol";
import "../security/OnlySelf.sol";
import "../../utils/Constants.sol";
import {IVault, FeatureSwitches} from "../interfaces/IVault.sol";
import "../interfaces/ITradingCore.sol";
import "../libraries/LibVault.sol";
import "../libraries/LibPriceFacade.sol";
import "../libraries/LibAccessControlEnumerable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

contract VaultFacet is IVault, OnlySelf {

    using Bits for uint;

    function addToken(
        address tokenAddress, uint16 feeBasisPoints, uint16 taxBasisPoints, bool stable,
        bool dynamicFee, bool asMargin, bool asBet, uint16[] calldata weights
    ) external override {
        LibAccessControlEnumerable.checkRole(Constants.TOKEN_OPERATOR_ROLE);
        require(feeBasisPoints < 1e4 && taxBasisPoints < 1e4, "VaultFacet: The value of feeBasisPoints or taxBasisPoints is too large");
        require(tokenAddress != address(0), "VaultFacet: Token address can't be 0 address");
        uint featureSwitches = 0;
        featureSwitches = featureSwitches.setOrClearBit(uint8(FeatureSwitches.AS_MARGIN), asMargin);
        featureSwitches = featureSwitches.setOrClearBit(uint8(FeatureSwitches.AS_BET), asBet);
        LibVault.addToken(tokenAddress, feeBasisPoints, taxBasisPoints, stable, dynamicFee, uint8(featureSwitches), weights);
    }

    function removeToken(address tokenAddress, uint16[] calldata weights) external override {
        LibAccessControlEnumerable.checkRole(Constants.TOKEN_OPERATOR_ROLE);
        require(tokenAddress != address(0), "VaultFacet: Token address can't be 0 address");
        LibVault.removeToken(tokenAddress, weights);
    }

    function updateToken(address tokenAddress, uint16 feeBasisPoints, uint16 taxBasisPoints, bool dynamicFee) external override {
        LibAccessControlEnumerable.checkRole(Constants.TOKEN_OPERATOR_ROLE);
        require(feeBasisPoints < 1e4 && taxBasisPoints < 1e4, "VaultFacet: The value of feeBasisPoints or taxBasisPoints is too large");
        require(tokenAddress != address(0), "VaultFacet: Token address can't be 0 address");
        LibVault.updateToken(tokenAddress, feeBasisPoints, taxBasisPoints, dynamicFee);
    }

    function updateTokenFeature(address tokenAddress, bool asMargin, bool asBet) external override {
        LibAccessControlEnumerable.checkRole(Constants.TOKEN_OPERATOR_ROLE);
        require(tokenAddress != address(0), "VaultFacet: Token address can't be 0 address");
        uint featureSwitches = 0;
        featureSwitches = featureSwitches.setOrClearBit(uint8(FeatureSwitches.AS_MARGIN), asMargin);
        featureSwitches = featureSwitches.setOrClearBit(uint8(FeatureSwitches.AS_BET), asBet);
        LibVault.updateTokenFeature(tokenAddress, uint8(featureSwitches));
    }

    function changeWeight(uint16[] calldata weights) external override {
        LibAccessControlEnumerable.checkRole(Constants.TOKEN_OPERATOR_ROLE);
        LibVault.changeWeight(weights);
    }

    // The value of securityMarginRate can be greater than 10000
    function setSecurityMarginP(uint16 _securityMarginP) external override {
        LibAccessControlEnumerable.checkRole(Constants.ADMIN_ROLE);
        require(_securityMarginP > 0, "VaultFacet: Invalid securityMarginP");
        LibVault.setSecurityMarginP(_securityMarginP);
    }

    function securityMarginP() external view override returns (uint16) {
        return LibVault.vaultStorage().securityMarginP;
    }

    function tokensV3() external view override returns (Token[] memory) {
        LibVault.VaultStorage storage vs = LibVault.vaultStorage();
        Token[] memory tokens = new Token[](vs.tokenAddresses.length);
        for (uint256 i; i < vs.tokenAddresses.length; i++) {
            tokens[i] = getTokenByAddress(vs.tokenAddresses[i]);
        }
        return tokens;
    }

    function getTokenByAddress(address tokenAddress) public view override returns (Token memory) {
        LibVault.AvailableToken memory at = LibVault.getTokenByAddress(tokenAddress);
        return Token(
            at.tokenAddress, at.weight, at.feeBasisPoints,
            at.taxBasisPoints, at.stable, at.dynamicFee,
            uint(at.featureSwitches).bitSet(uint8(FeatureSwitches.AS_MARGIN)),
            uint(at.featureSwitches).bitSet(uint8(FeatureSwitches.AS_BET))
        );
    }

    function getTokenForTrading(address tokenAddress) external view override returns (MarginToken memory) {
        LibVault.AvailableToken memory at = LibVault.getTokenByAddress(tokenAddress);
        return MarginToken(
            at.tokenAddress, uint(at.featureSwitches).bitSet(uint8(FeatureSwitches.AS_MARGIN)),
            at.decimals, LibPriceFacade.getPrice(tokenAddress)
        );
    }

    function getTokenForPrediction(address tokenAddress) external view override returns (MarginToken memory) {
        LibVault.AvailableToken memory at = LibVault.getTokenByAddress(tokenAddress);
        return MarginToken(
            at.tokenAddress, uint(at.featureSwitches).bitSet(uint8(FeatureSwitches.AS_BET)),
            at.decimals, LibPriceFacade.getPrice(tokenAddress)
        );
    }

    function itemValue(address token) external view override returns (LpItem memory lpItem) {
        LibVault.VaultStorage storage vs = LibVault.vaultStorage();
        LibVault.AvailableToken storage at = vs.tokens[token];
        require(at.tokenAddress != address(0), "VaultFacet: token does not exist");
        return _itemValue(at, vs.treasury[token]);
    }

    function _itemValue(LibVault.AvailableToken storage at, uint256 tokenValue) private view returns (IVault.LpItem memory lpItem) {
        address tokenAddress = at.tokenAddress;
        uint256 price = LibPriceFacade.getPrice(tokenAddress);
        uint256 valueUsd = price * tokenValue * 1e10 / (10 ** at.decimals);
        lpItem = IVault.LpItem(
            tokenAddress, int256(tokenValue), at.decimals, int256(valueUsd),
            at.weight, at.feeBasisPoints, at.taxBasisPoints, at.dynamicFee
        );
    }

    function totalValue() external view override returns (LpItem[] memory lpItems) {
        LibVault.VaultStorage storage vs = LibVault.vaultStorage();
        address[] storage tokenAddresses = vs.tokenAddresses;
        lpItems = new IVault.LpItem[](tokenAddresses.length);
        for (uint256 i; i < tokenAddresses.length; i++) {
            LibVault.AvailableToken storage at = vs.tokens[tokenAddresses[i]];
            lpItems[i] = _itemValue(at, vs.treasury[tokenAddresses[i]]);
        }
    }

    function increase(address token, uint256 amount) external onlySelf override {
        LibVault.VaultStorage storage vs = LibVault.vaultStorage();
        vs.treasury[token] += amount;
    }

    function decreaseByCloseTrade(address token, uint256 amount) external onlySelf override returns (ITradingClose.SettleToken[] memory) {
        return LibVault.decreaseByCloseTrade(token, amount);
    }

    function decrease(address token, uint256 amount) external onlySelf override {
        LibVault.VaultStorage storage vs = LibVault.vaultStorage();
        require(vs.treasury[token] >= amount, "VaultFacet: Treasury insufficient balance");
        vs.treasury[token] -= amount;
    }

    function maxWithdrawAbleUsd() external view returns (int256) {
        (int256 lpUnPnlUsd,) = ITradingCore(address(this)).lpUnrealizedPnlUsd();
        return LibVault.maxWithdrawAbleUsd(LibVault.getTotalValueUsd() + lpUnPnlUsd);
    }
}
