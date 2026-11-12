// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Kinetiq StakingManager.deactivateValidator (Pashov H-02, 2025-02).
    SYNTHETIC, cheatcode-free. Deactivate records a rebalance request and
    never calls processValidatorWithdrawals, so 1,000 HYPE stays in the
    validator. The control withdraws that 1,000 to the staking manager. */

contract Hype {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingManager {
    Hype public hype;
    bool public pullOnDeactivate;
    address public validator;
    uint256 public requested;
    uint256 public withdrawn;
    bool public active = true;

    constructor(Hype _hype, address _validator, bool _pull) {
        hype = _hype;
        validator = _validator;
        pullOnDeactivate = _pull;
    }

    function fundValidator(uint256 amount) external {
        hype.mint(validator, amount);
    }

    function deactivateValidator() external {
        require(active, "inactive");
        uint256 bal = hype.balanceOf(validator);
        if (bal > 0) {
            // @> VULN: a rebalance request is stored and the validator balance is never withdrawn.
            requested = bal;
        }
        active = false;
        if (pullOnDeactivate) {
            processValidatorWithdrawals();
        }
    }

    function processValidatorWithdrawals() public {
        uint256 bal = hype.balanceOf(validator);
        Validator(validator).push(address(this), bal);
        withdrawn = bal;
    }
}

contract Validator {
    Hype public hype;
    constructor(Hype _hype) {
        hype = _hype;
    }
    function push(address to, uint256 amount) external {
        hype.transfer(to, amount);
    }
}

contract Exploit {
    uint256 public constant STUCK = 1_000e18;

    Hype public hype; // nonce 1
    Validator public validator; // nonce 2
    StakingManager public manager; // nonce 3
    Validator public fairValidator; // nonce 4
    StakingManager public fairManager; // nonce 5

    uint256 public leftOnValidator;
    uint256 public managerReceived;
    uint256 public controlLeft;
    uint256 public controlReceived;

    constructor() {
        hype = new Hype();
        validator = new Validator(hype);
        manager = new StakingManager(hype, address(validator), false);
        fairValidator = new Validator(hype);
        fairManager = new StakingManager(hype, address(fairValidator), true);
    }

    function run() external {
        manager.fundValidator(STUCK);
        manager.deactivateValidator();
        leftOnValidator = hype.balanceOf(address(validator));
        managerReceived = hype.balanceOf(address(manager));

        fairManager.fundValidator(STUCK);
        fairManager.deactivateValidator();
        controlLeft = hype.balanceOf(address(fairValidator));
        controlReceived = hype.balanceOf(address(fairManager));

        require(manager.requested() == STUCK, "request recorded");
        require(manager.withdrawn() == 0, "vuln withdrew");
        require(leftOnValidator == STUCK, "1000 stuck");
        require(managerReceived == 0, "manager empty");
        require(controlLeft == 0, "control validator not empty");
        require(controlReceived == STUCK, "control did not pay 1000");
    }
}
