// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Onchain Heroes Dragma._calculateBonusRewards — Mythical weapons mint 0 shards
    (Shieldify, H-02, July 2025).
    SYNTHETIC, cheatcode-free, one block. WEAPON_SHARD_TABLE is the 48-bit
    constant from the report (0xD282321E140A): six rarity bytes, indices 0-5.
    Rarity 6 (Mythical) shifts that word by 48 bits, the byte is 0, and the
    hero is minted nothing. The published Mythic coefficient is 210 (0xD2).
    Appended, the table is 0xD2D282321E140A. At zone 3 that is 2,100 chance
    units, so 2 shards are guaranteed. With requestId 0 and random 0 the
    remainder roll is 117, which does not add a third shard. N = 2.
    A Legendary hero (rarity 5) reads the same 210-byte and is paid 2.
    Control deploys the 56-bit table and pays the Mythical hero those 2. */

contract Shard {
    string public constant name = "Weapon Shard";
    string public constant symbol = "SHARD";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        require(id == 1, "shard id");
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract Dragma {
    uint256 public constant WEAPON_SHARD_TABLE = 0xD282321E140A;

    struct Hero {
        address owner;
        uint256 rarity;
        uint256 zone;
    }

    Shard public items;
    mapping(uint256 => Hero) public heroes;

    constructor(Shard items_) {
        items = items_;
    }

    function setHero(uint256 heroId, address owner, uint256 rarity, uint256 zone) external {
        heroes[heroId] = Hero(owner, rarity, zone);
    }

    function claimBonus(uint256 heroId, uint256 requestId, uint256 randomNumber_)
        external
        returns (uint256, uint256)
    {
        return _calculateBonusRewards(heroId, requestId, randomNumber_);
    }

    function _calculateBonusRewards(uint256 heroId, uint256 requestId, uint256 randomNumber_)
        internal
        returns (uint256, uint256)
    {
        Hero memory hero = heroes[heroId];
        uint256 rarity = hero.rarity;
        uint256 zone = hero.zone;
        uint256 gachaTokenId = 0;

        // @> VULN: rarity 6 shifts the 48-bit table by 48 bits and the shard byte is 0
        uint256 weaponShardChance = (((WEAPON_SHARD_TABLE >> (rarity * 8)) & 0xff) * (25 + (zone * 25))) / 10;

        uint256 guaranteedMint = weaponShardChance / 1000;

        if (weaponShardChance != 0) {
            uint256 chance = weaponShardChance - (guaranteedMint * 1000);
            randomNumber_ = uint256(keccak256(abi.encode(randomNumber_, requestId)));
            if ((randomNumber_ % 1000) < chance) {
                guaranteedMint += 1;
            }
        }
        if (guaranteedMint > 0) {
            items.mint(hero.owner, 1, guaranteedMint);
        }
        return (gachaTokenId, guaranteedMint);
    }
}

contract DragmaFixed {
    uint256 public constant WEAPON_SHARD_TABLE = 0xD2D282321E140A;

    struct Hero {
        address owner;
        uint256 rarity;
        uint256 zone;
    }

    Shard public items;
    mapping(uint256 => Hero) public heroes;

    constructor(Shard items_) {
        items = items_;
    }

    function setHero(uint256 heroId, address owner, uint256 rarity, uint256 zone) external {
        heroes[heroId] = Hero(owner, rarity, zone);
    }

    function claimBonus(uint256 heroId, uint256 requestId, uint256 randomNumber_)
        external
        returns (uint256, uint256)
    {
        Hero memory hero = heroes[heroId];
        uint256 rarity = hero.rarity;
        uint256 zone = hero.zone;
        uint256 gachaTokenId = 0;

        // FIX: 56-bit table, Mythic byte 0xD2 sits at rarity 6
        uint256 weaponShardChance = (((WEAPON_SHARD_TABLE >> (rarity * 8)) & 0xff) * (25 + (zone * 25))) / 10;

        uint256 guaranteedMint = weaponShardChance / 1000;

        if (weaponShardChance != 0) {
            uint256 chance = weaponShardChance - (guaranteedMint * 1000);
            randomNumber_ = uint256(keccak256(abi.encode(randomNumber_, requestId)));
            if ((randomNumber_ % 1000) < chance) {
                guaranteedMint += 1;
            }
        }
        if (guaranteedMint > 0) {
            items.mint(hero.owner, 1, guaranteedMint);
        }
        return (gachaTokenId, guaranteedMint);
    }
}

contract Exploit {
    uint256 public constant HERO_ID = 1;
    uint256 public constant LEGEND_ID = 2;
    uint256 public constant MYTHIC = 6;
    uint256 public constant LEGENDARY = 5;
    uint256 public constant ZONE = 3;
    uint256 public constant N = 2;
    address public constant LEGENDARY_HERO = 0x000000000000000000000000000000000000bEEF;

    Shard public items;
    Dragma public dragma;
    uint256 public claimed;
    uint256 public owed;
    uint256 public legendaryPaid;

    constructor() {
        items = new Shard();
        dragma = new Dragma(items);
    }

    function fairShards(uint256 rarity, uint256 zone, uint256 requestId, uint256 randomNumber_)
        public
        pure
        returns (uint256 guaranteedMint)
    {
        uint256 weaponShardChance = (((uint256(0xD2D282321E140A) >> (rarity * 8)) & 0xff) * (25 + (zone * 25))) / 10;
        guaranteedMint = weaponShardChance / 1000;
        if (weaponShardChance != 0) {
            uint256 chance = weaponShardChance - (guaranteedMint * 1000);
            randomNumber_ = uint256(keccak256(abi.encode(randomNumber_, requestId)));
            if ((randomNumber_ % 1000) < chance) guaranteedMint += 1;
        }
    }

    function run() external {
        address hero = msg.sender;
        dragma.setHero(HERO_ID, hero, MYTHIC, ZONE);
        (, uint256 minted) = dragma.claimBonus(HERO_ID, 0, 0);
        claimed = minted;
        owed = fairShards(MYTHIC, ZONE, 0, 0);
        require(claimed == 0, "mythical claim was not zero");
        require(owed == N, "fair table does not owe N");
        require(items.balanceOf(hero) == 0, "mythical hero was paid");

        dragma.setHero(LEGEND_ID, LEGENDARY_HERO, LEGENDARY, ZONE);
        (, uint256 legendMint) = dragma.claimBonus(LEGEND_ID, 0, 0);
        legendaryPaid = legendMint;
        require(legendaryPaid == N, "legendary was not paid N");
        require(items.balanceOf(LEGENDARY_HERO) == N, "legendary balance");
        require(items.balanceOf(hero) == 0, "mythical hero received shards");
    }
}
