// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Penguingotchi — dead penguins still count toward the alive cap (Shieldify, H-02)
    SYNTHETIC, cheatcode-free reduction.
    checkCanGetExtraPenguin reads playerOwnedPenguins.length, which keeps
    dead penguins. maxAlivePenguins is 2. After one of two penguins dies,
    a third buy reverts. 100 PENG cannot be spent. The control counts
    alivePenguins and the third buy spends the 100. */

contract PengToken {
    string public constant symbol = "PENG";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PenguinManager {
    struct Limits {
        uint256 maxAlivePenguins;
    }

    struct Settings {
        Limits limits;
    }

    PengToken public peng;
    Settings public settings;
    uint256 public price = 100e18;
    uint256 public nextId = 1;
    mapping(address => uint256[]) public owned;
    mapping(address => uint256) public aliveCount;

    constructor(PengToken token, uint256 maxAlive) {
        peng = token;
        settings.limits.maxAlivePenguins = maxAlive;
    }

    modifier checkCanGetExtraPenguin(address owner) {
        uint256[] memory penguinIds = owned[owner];
        uint256 penguinCount = penguinIds.length;
        // @> VULN: playerOwnedPenguins keeps dead penguins, so the alive cap counts them too
        if (penguinCount >= settings.limits.maxAlivePenguins) {
            revert("MaximumPenguinsAcquired");
        }
        _;
    }

    function buyPenguin(address owner) external checkCanGetExtraPenguin(owner) {
        peng.transferFrom(owner, address(this), price);
        uint256 id = nextId;
        nextId = id + 1;
        owned[owner].push(id);
        aliveCount[owner] += 1;
    }

    function killPenguin(address owner) external {
        require(aliveCount[owner] > 0, "none alive");
        aliveCount[owner] -= 1;
    }

    function ownedCount(address owner) external view returns (uint256) {
        return owned[owner].length;
    }
}

contract FixedPenguinManager {
    PengToken public peng;
    uint256 public maxAlivePenguins;
    uint256 public price = 100e18;
    uint256 public nextId = 1;
    mapping(address => uint256) public ownedCount;
    mapping(address => uint256) public aliveCount;

    constructor(PengToken token, uint256 maxAlive) {
        peng = token;
        maxAlivePenguins = maxAlive;
    }

    function buyPenguin(address owner) external {
        require(aliveCount[owner] < maxAlivePenguins, "alive cap");
        peng.transferFrom(owner, address(this), price);
        ownedCount[owner] += 1;
        aliveCount[owner] += 1;
        nextId += 1;
    }

    function killPenguin(address owner) external {
        require(aliveCount[owner] > 0, "none alive");
        aliveCount[owner] -= 1;
    }
}

contract Exploit {
    PengToken public peng;
    PenguinManager public manager;
    FixedPenguinManager public fixedManager;
    uint256 public constant PRICE = 100e18;
    uint256 public constant WALLET = 300e18;

    constructor() {
        peng = new PengToken();
        manager = new PenguinManager(peng, 2);
        fixedManager = new FixedPenguinManager(peng, 2);
    }

    function run() external {
        address player = address(this);
        peng.mint(player, WALLET);
        peng.approve(address(manager), type(uint256).max);
        peng.approve(address(fixedManager), type(uint256).max);
        manager.buyPenguin(player);
        manager.buyPenguin(player);
        manager.killPenguin(player);
        uint256 alive = manager.aliveCount(player);
        uint256 everOwned = manager.ownedCount(player);
        uint256 cashBefore = peng.balanceOf(player);
        (bool bought,) = address(manager).call(abi.encodeCall(PenguinManager.buyPenguin, (player)));
        uint256 cashAfter = peng.balanceOf(player);
        peng.mint(player, WALLET);
        fixedManager.buyPenguin(player);
        fixedManager.buyPenguin(player);
        fixedManager.killPenguin(player);
        fixedManager.buyPenguin(player);
        require(alive == 1, "one alive");
        require(everOwned == 2, "two ever owned");
        require(bought == false, "third buy reverted");
        require(cashBefore == PRICE, "100 left");
        require(cashAfter == PRICE, "100 cannot be spent");
        require(fixedManager.aliveCount(player) == 2, "control alive");
        require(peng.balanceOf(address(fixedManager)) == WALLET, "control spent 300");
        require(peng.balanceOf(player) == PRICE, "unspent 100 remains");
        peng.transfer(msg.sender, PRICE);
    }
}
