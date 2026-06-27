// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

interface IMunicipality {

    struct LastPurchaseData {
        uint256 lastPurchaseDate;
        uint256 expirationDate;
        uint256 dollarValue;
    }    
    struct BundleInfo {
        uint256 parcelsAmount;
        uint256 minersAmount;
        uint256 bundlePrice;
        uint256 discountPct;
    }

    struct SuperBundleInfo {
        uint256 parcelsAmount;
        uint256 minersAmount;
        uint256 upgradesAmount;
        uint256 vouchersAmount;
        uint256 discountPct;
    }
    
    struct MinerInf {
        uint256 totalHash;
        uint256 freeHash;
    }

    struct ParcelInf {
        uint256 parcelCount;
        uint256 freeSlots;
        uint256 NumUpgraded;
        uint256 claimedOnMap;
    }


    function lastPurchaseData(address) external view returns (LastPurchaseData memory);
    function attachMinerToParcel(address user, uint256 firstMinerId, uint256[] memory parcelIds) external;
    function isTokenLocked(address _tokenAddress, uint256 _tokenId) external view returns(bool);
    function userToPurchasedAmountMapping(address _tokenAddress) external view returns(uint256);
    function updateLastPurchaseDate(address _user, uint256 _timeStamp) external;
    function minerParcelMapping(uint256 _tokenId) external view returns(uint256);
    function newBundles(uint256) external view returns(BundleInfo memory bundle);
    function gigaBundles(uint256) external view returns(SuperBundleInfo memory);
    function dynamicSuperBundles(uint256) external view returns(SuperBundleInfo memory);
    function getPriceForBundle(uint8 _bundleType, uint8 _paymentType) external view returns(uint256, uint256, uint256);
    function getPriceForSuperBundle(uint8 _bundleType, address _user, uint8 _paymentType) external view returns(uint256, uint256, uint256, uint256);
    function setMinerInf(address _user, uint256 _totalHash, uint256 _freeHash) external;
    function minerInf(address _user) external view returns(MinerInf memory);
    function addFreeHash(address _user, uint256 _freeHash) external;
    function updatePMinfMining (address _oldAddress, address _newAddress) external;
    function storeAndMint(address _user, uint256 _parcelCount) external returns(uint256);
    function web2Mint(string memory _id) external;
    function purchaseInfo(address user, uint8 productId, uint256 prodCount, uint256 price, uint8 paymentMethod, uint256 gymAmount, uint256 hashPowerToSet, uint256 parcelCount) external;
    function parcelInf(address) external returns (ParcelInf memory);
    function currentlySoldStandardParcelsCount() external view returns (uint256);
}
