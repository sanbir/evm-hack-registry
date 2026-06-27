// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "./AttoDecimal.sol";
import "./ICorroborativeToken.sol";
import "./TwoStageOwnable.sol";

contract ZenterestPriceFeed is TwoStageOwnable {
    using AttoDecimalLib for AttoDecimal;

    bytes32 internal constant CORROBORATIVE_ETH_SYMBOL_COMPORATOR = keccak256(abi.encodePacked("zenETH"));

    struct Price {
        AttoDecimal value;
        uint256 updatedAt;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct PriceUpdate {
        address token;
        uint256 newPriceMantissa;
        uint256 updatedAt;
    }

    struct DelegatedPriceUpdate {
        address token;
        uint256 newPriceMantissa;
        uint256 updatedAt;
        Signature signature;
    }

    address private _reporter;
    mapping(address => Price) private _prices;

    function reporter() public view returns (address) {
        return _reporter;
    }

    function prices(address token) public view returns (Price memory price) {
        return _prices[token];
    }

    function assetPrices(address token) public view returns (uint256 price) {
        return _prices[token].value.mantissa;
    }

    function getUnderlyingPrice(ICorroborativeToken corroborative) public view returns (uint256) {
        if (keccak256(abi.encodePacked(corroborative.symbol())) == CORROBORATIVE_ETH_SYMBOL_COMPORATOR) {
            return AttoDecimalLib.ONE_MANTISSA;
        }
        return assetPrices(corroborative.underlying());
    }

    event PriceDelegated(
        address indexed token,
        address indexed submittedBy,
        uint256 newPriceMantissa,
        uint256 updatedAt,
        uint8 v,
        bytes32 r,
        bytes32 s
    );

    event PriceUpdated(address indexed token, uint256 newPriceMantissa, uint256 updatedAt);
    event ReporterChanged(address reporter);

    constructor(address owner_, address reporter_) public TwoStageOwnable(owner_) {
        _changeReporter(reporter_);
    }

    function changeReporter(address newReporterAddress) external onlyOwner returns (bool success) {
        _changeReporter(newReporterAddress);
        return true;
    }

    function updateDelegatedPrice(DelegatedPriceUpdate memory update)
        external
        UpdatingTimeInPast(update.updatedAt)
        returns (bool success)
    {
        _delegatedPriceUpdate(update);
        return true;
    }

    function updateDelegatedPricesBatch(DelegatedPriceUpdate[] memory updates)
        external
        returns (uint256 updatedPricesCount)
    {
        uint256 updatesCount = updates.length;
        for (uint256 i = 0; i < updatesCount; i++) {
            DelegatedPriceUpdate memory update = updates[i];
            _checkUpdatingTime(update.updatedAt);
            Price storage actualPrice = _prices[update.token];
            if (actualPrice.updatedAt >= update.updatedAt) continue;
            _delegatedPriceUpdate(update);
            updatedPricesCount += 1;
        }
    }

    function updateDelegatedPricesSet(PriceUpdate[] memory updates, Signature memory signature)
        external
        returns (uint256 updatedPricesCount)
    {
        uint256 updatesCount = updates.length;
        uint256[] memory splittedUpdates = new uint256[](updatesCount * 3);
        uint256 pointer = 0;
        for (uint256 updateIndex = 0; updateIndex < updatesCount; updateIndex++) {
            PriceUpdate memory update = updates[updateIndex];
            splittedUpdates[pointer] = uint256(update.token);
            splittedUpdates[pointer + 1] = update.newPriceMantissa;
            splittedUpdates[pointer + 2] = update.updatedAt;
            pointer += 3;
        }
        bytes memory encodedUpdates = abi.encodePacked(splittedUpdates);
        _checkSignerIsReporter(encodedUpdates, signature);
        return _updatePricesBatch(updates);
    }

    function updatePrice(PriceUpdate memory update)
        external
        UpdatingTimeInPast(update.updatedAt)
        returns (bool success)
    {
        require(msg.sender == _reporter, "Caller not reporter");
        _updatePrice(update.token, update.newPriceMantissa, update.updatedAt);
        return true;
    }

    function updatePricesBatch(PriceUpdate[] memory updates) external returns (uint256 updatedPricesCount) {
        require(msg.sender == _reporter, "Caller not reporter");
        return _updatePricesBatch(updates);
    }

    function _checkSignerIsReporter(bytes memory data, Signature memory signature) internal view {
        bytes32 hash_ = keccak256(data);
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 prefixedHash = keccak256(abi.encodePacked(prefix, hash_));
        address signer = ecrecover(prefixedHash, signature.v, signature.r, signature.s);
        require(signer == _reporter, "Invalid signature");
    }

    function _checkUpdatingTime(uint256 updatingTime) internal view {
        require(updatingTime <= block.timestamp, "Invalid updating time");
    }

    function _changeReporter(address newReporterAddress) internal {
        if (_reporter == newReporterAddress) return;
        _reporter = newReporterAddress;
        emit ReporterChanged(newReporterAddress);
    }

    function _delegatedPriceUpdate(DelegatedPriceUpdate memory update) internal {
        bytes memory encodedUpdate = abi.encodePacked(update.token, update.newPriceMantissa, update.updatedAt);
        _checkSignerIsReporter(encodedUpdate, update.signature);
        emit PriceDelegated(
            update.token,
            msg.sender,
            update.newPriceMantissa,
            update.updatedAt,
            update.signature.v,
            update.signature.r,
            update.signature.s
        );
        _updatePrice(update.token, update.newPriceMantissa, update.updatedAt);
    }

    function _updatePrice(
        address token,
        uint256 newPriceMantissa,
        uint256 updatedAt
    ) internal {
        Price storage actualPrice = _prices[token];
        uint256 lastUpdatedAt = actualPrice.updatedAt;
        require(lastUpdatedAt < updatedAt, "Price already updated");
        actualPrice.value = AttoDecimal({mantissa: newPriceMantissa});
        actualPrice.updatedAt = updatedAt;
        emit PriceUpdated(token, newPriceMantissa, updatedAt);
    }

    function _updatePricesBatch(PriceUpdate[] memory updates) internal returns (uint256 updatedPricesCount) {
        uint256 updatesCount = updates.length;
        for (uint256 i = 0; i < updatesCount; i++) {
            PriceUpdate memory update = updates[i];
            _checkUpdatingTime(update.updatedAt);
            Price storage actualPrice = _prices[update.token];
            if (actualPrice.updatedAt >= update.updatedAt) continue;
            _updatePrice(update.token, update.newPriceMantissa, update.updatedAt);
            updatedPricesCount += 1;
        }
    }

    modifier UpdatingTimeInPast(uint256 updatingTime) {
        _checkUpdatingTime(updatingTime);
        _;
    }
}
