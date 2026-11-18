// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Bunni — poolManager.sync before unlock (Pashov, August 2024, H-01)
    SYNTHETIC, cheatcode-free reduction of BunniHook.rebalanceOrderPostHook.
    sync() is onlyWhenUnlocked. The hook calls it before unlock(), so the
    post-hook reverts. 60 ether of order output stays in the hook and the
    pool reserves stay 0. */

contract ERC20 {
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract PoolManager {
    bool public unlocked;
    address public syncedCurrency;
    uint256 public syncedBalance;
    ERC20 public settled;

    error ManagerLocked();

    modifier onlyWhenUnlocked() {
        if (!unlocked) revert ManagerLocked(); // S3
        _;
    }

    function sync(address currency) external onlyWhenUnlocked {
        syncedCurrency = currency; // S4 reached only after unlock
        syncedBalance = ERC20(currency).balanceOf(address(this));
    }

    function unlock(bytes calldata data) external {
        unlocked = true; // S5
        IUnlock(msg.sender).unlockCallback(data);
        unlocked = false;
    }
}

interface IUnlock {
    function unlockCallback(bytes calldata data) external;
}

contract BunniHook {
    PoolManager public poolManager;
    ERC20 public token;
    uint256 public orderOutputAmount;
    bool public rebalanced;

    constructor(PoolManager p, ERC20 t) {
        poolManager = p;
        token = t;
    }

    function setOutput(uint256 amount) external {
        orderOutputAmount = amount; // S1
    }

    function rebalanceOrderPostHook() external {
        poolManager.sync(address(token)); // @> VULN: sync runs before unlock, and sync requires the lock to be open
        if (address(token) != address(0)) {
            token.transfer(address(poolManager), orderOutputAmount);
        }
        poolManager.unlock(abi.encode(orderOutputAmount));
    }

    function unlockCallback(bytes calldata) external {
        poolManager.sync(address(token));
        rebalanced = true;
    }
}

contract Exploit {
    uint256 public constant FINDING = 43546;
    uint256 public constant OUTPUT = 60 ether;
    ERC20 public token;
    PoolManager public poolManager;
    BunniHook public hook;
    bool public rebalanceReverted;

    constructor() {
        token = new ERC20("USDC", 18);
        poolManager = new PoolManager();
        hook = new BunniHook(poolManager, token);
    }

    function run() external {
        token.mint(address(hook), OUTPUT); // S2 order output sits on the hook
        hook.setOutput(OUTPUT);
        try hook.rebalanceOrderPostHook() {
            revert("rebalanced");
        } catch {
            rebalanceReverted = true; // S6
        }
        require(rebalanceReverted, "expected revert");
        require(!hook.rebalanced(), "flag");
        require(poolManager.syncedCurrency() == address(0), "not synced");
        require(token.balanceOf(address(hook)) == OUTPUT, "stuck");
        require(token.balanceOf(address(poolManager)) == 0, "pool empty");
    }
}
