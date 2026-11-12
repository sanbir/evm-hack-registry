// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Onchain Heroes Dragma._calculateBonusRewards — bronze gacha is never
    minted (Shieldify, H-01, July 2025).
    SYNTHETIC, cheatcode-free, one block.
    BONUS_REWARD_TABLE packs four tiers in one word: rainbow, gold, silver,
    bronze. The loop stops at i < 3, so bits 24-31 are never read.
    Rarity 0, zone 6, bronze byte 255. Chance is 4462. keccak(0, 0) % 10000
    is 4117, which would hit bronze and miss the three zero bytes.
    The claim returns token id 0 and mints 0. The i < 4 loop owes N = 1.
    Control runs i < 4 and mints that 1 bronze token to the hero. */

contract Bronze {
    string public constant name = "Bronze Gacha";
    string public constant symbol = "BRNZ";
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        require(id == 1, "bronze id");
        balanceOf[to] += amount;
    }
}

contract Dragma {
    // bronze byte (bits 24-31) = 255. Rainbow, gold, and silver bytes are 0.
    uint256 public constant BONUS_REWARD_TABLE = uint256(255) << 24;

    struct Hero {
        address owner;
        uint256 rarity;
        uint256 zone;
    }

    Bronze public items;
    mapping(uint256 => Hero) public heroes;

    constructor(Bronze items_) {
        items = items_;
    }

    function setHero(uint256 heroId, address owner, uint256 rarity, uint256 zone) external {
        heroes[heroId] = Hero(owner, rarity, zone);
    }

    function claimBonus(uint256 heroId, uint256 requestId, uint256 randomNumber_) external returns (uint256) {
        return _calculateBonusRewards(heroId, requestId, randomNumber_);
    }

    function _calculateBonusRewards(uint256 heroId, uint256 requestId, uint256 randomNumber_)
        internal
        returns (uint256)
    {
        Hero memory hero = heroes[heroId];
        uint256 rarity = hero.rarity;
        uint256 zone = hero.zone;

        uint256 rewards = (BONUS_REWARD_TABLE >> (rarity * 32)) & 0xffffffff;

        uint256 gachaTokenId;
        if (rewards != 0) {
            randomNumber_ = uint256(keccak256(abi.encode(randomNumber_, requestId)));
            // @> VULN: i < 3 never reads the bronze byte in bits 24-31
            for (uint256 i = 0; i < 3; i++) {
                uint256 chance = (((rewards >> (i * 8)) & 0xff) * (25 + (zone * 25))) / 10;
                if ((randomNumber_ % 10000) < chance) {
                    gachaTokenId = (4 - i);
                    items.mint(hero.owner, gachaTokenId, 1);
                    break;
                }
            }
        }
        return gachaTokenId;
    }
}

contract DragmaFixed {
    uint256 public constant BONUS_REWARD_TABLE = uint256(255) << 24;

    struct Hero {
        address owner;
        uint256 rarity;
        uint256 zone;
    }

    Bronze public items;
    mapping(uint256 => Hero) public heroes;

    constructor(Bronze items_) {
        items = items_;
    }

    function setHero(uint256 heroId, address owner, uint256 rarity, uint256 zone) external {
        heroes[heroId] = Hero(owner, rarity, zone);
    }

    function claimBonus(uint256 heroId, uint256 requestId, uint256 randomNumber_) external returns (uint256) {
        Hero memory hero = heroes[heroId];
        uint256 rarity = hero.rarity;
        uint256 zone = hero.zone;
        uint256 rewards = (BONUS_REWARD_TABLE >> (rarity * 32)) & 0xffffffff;
        uint256 gachaTokenId;
        if (rewards != 0) {
            randomNumber_ = uint256(keccak256(abi.encode(randomNumber_, requestId)));
            // FIX: i < 4 reads the bronze byte
            for (uint256 i = 0; i < 4; i++) {
                uint256 chance = (((rewards >> (i * 8)) & 0xff) * (25 + (zone * 25))) / 10;
                if ((randomNumber_ % 10000) < chance) {
                    gachaTokenId = (4 - i);
                    items.mint(hero.owner, gachaTokenId, 1);
                    break;
                }
            }
        }
        return gachaTokenId;
    }
}

contract Exploit {
    uint256 public constant HERO_ID = 1;
    uint256 public constant RARITY = 0;
    uint256 public constant ZONE = 6;
    uint256 public constant N = 1;

    Bronze public items;
    Dragma public dragma;
    uint256 public claimed;
    uint256 public owed;
    address public hero;

    constructor() {
        items = new Bronze();
        dragma = new Dragma(items);
    }

    function fairBronze(uint256 rarity, uint256 zone, uint256 requestId, uint256 randomNumber_)
        public
        pure
        returns (uint256 tokenId)
    {
        uint256 rewards = ((uint256(255) << 24) >> (rarity * 32)) & 0xffffffff;
        if (rewards == 0) return 0;
        randomNumber_ = uint256(keccak256(abi.encode(randomNumber_, requestId)));
        for (uint256 i = 0; i < 4; i++) {
            uint256 chance = (((rewards >> (i * 8)) & 0xff) * (25 + (zone * 25))) / 10;
            if ((randomNumber_ % 10000) < chance) return (4 - i);
        }
        return 0;
    }

    function run() external {
        hero = msg.sender;
        dragma.setHero(HERO_ID, hero, RARITY, ZONE);
        claimed = dragma.claimBonus(HERO_ID, 0, 0);
        owed = fairBronze(RARITY, ZONE, 0, 0) == 1 ? N : 0;
        require(claimed == 0, "bronze claim was not zero");
        require(owed == N, "four-tier loop does not owe N");
        require(items.balanceOf(hero) == 0, "hero was paid");
    }
}
