// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
 * AuditVault 57634 — Onemind FeePayer.handleMintFee (Zokyo, 2022-10).
 * The ETH call()'s success flag is ignored. A reverting receiver does not
 * revert the mint, and the ETH stays in the FeePayer.
 */

contract RejectEth {
    receive() external payable {
        revert("no eth");
    }
}

contract FeePayer {
    RejectEth public immutable feeReceiver;
    uint256 public mintCount;
    uint256 public stuckRecorded;

    constructor(RejectEth _feeReceiver) {
        feeReceiver = _feeReceiver;
    }

    function handleMintFee() external payable {
        // @> VULN: call() success is ignored, so a failed ETH transfer does not revert
        (bool ok,) = address(feeReceiver).call{value: msg.value}("");
        mintCount += 1;
        if (!ok) stuckRecorded = msg.value;
    }
}

contract FeePayerFixed {
    RejectEth public immutable feeReceiver;
    uint256 public mintCount;

    constructor(RejectEth _feeReceiver) {
        feeReceiver = _feeReceiver;
    }

    function handleMintFee() external payable {
        (bool ok,) = address(feeReceiver).call{value: msg.value}("");
        require(ok, "fee transfer");
        mintCount += 1;
    }
}

contract Exploit {
    uint256 public constant FEE = 1 ether;

    RejectEth public rejecter;
    FeePayer public feePayer;
    uint256 public stuck;
    uint256 public mints;

    constructor() {
        rejecter = new RejectEth();
        feePayer = new FeePayer(rejecter);
    }

    function run() external payable {
        require(msg.value == FEE, "value");
        uint256 beforeBal = address(feePayer).balance;
        feePayer.handleMintFee{value: msg.value}();
        stuck = address(feePayer).balance - beforeBal;
        mints = feePayer.mintCount();
        require(stuck == FEE, "stuck");
        require(mints == 1, "mint continued");
        require(address(rejecter).balance == 0, "receiver empty");
        require(feePayer.stuckRecorded() == FEE, "recorded");
    }
}
