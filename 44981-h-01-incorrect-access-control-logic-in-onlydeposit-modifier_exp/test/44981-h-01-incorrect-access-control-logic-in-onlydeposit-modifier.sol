// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Nexus — onlyDeposit uses OR instead of AND (Pashov, finding #44981)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: `msg.sender != depositETH || msg.sender != depositUSD` is
    true for every address, including the two deposit contracts the modifier
    exists to allow. sendMessage always reverts, so neither deposit contract
    can announce a bridge message and the destination credit stays zero. */

error NotDepositContract(address sender);

contract Messaging {
    address public depositETH;
    address public depositUSD;
    bool public fixedMode;
    uint256 public sent;
    uint256 public attempts;
    bytes public lastData;

    constructor(bool fixed_) {
        fixedMode = fixed_;
    }

    function setDeposits(address ethDep, address usdDep) external {
        depositETH = ethDep;
        depositUSD = usdDep;
    }

    modifier onlyDeposit() {
        attempts++;
        if (fixedMode) {
            // FIX: reject only when the caller is neither deposit contract
            if (msg.sender != depositETH && msg.sender != depositUSD) revert NotDepositContract(msg.sender);
        } else if (msg.sender != depositETH || msg.sender != depositUSD) {
            revert NotDepositContract(msg.sender); // @> VULN: OR is true for every caller, including both deposit contracts
        }
        _;
    }

    function sendMessage(bytes calldata data, uint32 destId, uint256 lzFee) external payable onlyDeposit {
        require(destId == 101, "dest");
        sent += 1;
        lastData = data;
        lzFee;
    }
}

contract Deposit {
    Messaging public m;
    uint256 public escrow;

    constructor(Messaging messaging) {
        m = messaging;
    }

    function bridge(bytes calldata data) external payable {
        escrow += msg.value;
        m.sendMessage(data, 101, msg.value);
        escrow = 0;
    }
}

contract Exploit {
    Messaging public messaging; // nonce 1
    Deposit public depositETH; // nonce 2
    Deposit public depositUSD; // nonce 3
    bool public ethRejected;
    bool public usdRejected;

    constructor() {
        messaging = new Messaging(false);
        depositETH = new Deposit(messaging);
        depositUSD = new Deposit(messaging);
        messaging.setDeposits(address(depositETH), address(depositUSD));
    }

    function run() external {
        (bool okEth,) = address(depositETH).call(abi.encodeWithSelector(Deposit.bridge.selector, bytes("eth-user")));
        ethRejected = !okEth;
        (bool okUsd,) = address(depositUSD).call(abi.encodeWithSelector(Deposit.bridge.selector, bytes("usd-user")));
        usdRejected = !okUsd;
        require(ethRejected, "depositETH was accepted");
        require(usdRejected, "depositUSD was accepted");
        require(messaging.sent() == 0, "a bridge message was delivered");
    }
}
