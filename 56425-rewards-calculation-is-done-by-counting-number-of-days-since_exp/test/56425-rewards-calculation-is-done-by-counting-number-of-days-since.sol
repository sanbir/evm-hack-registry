// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  CWBC Arkouda — Zokyo, 2022-02-27.
    getPendingReward counts whole days since the last transfer.
    The spec accrues the daily tier continuously, by the second.
    A holder of 1.5 days is paid 1 day. No owner call is required.

    LAST_TRANSFER is the NFT's stored transfer time, not block.timestamp.
    The replay block is 1_700_129_600, which is 129_600 seconds later.
    Tier reward is 3 ARK per day (the documented minimum tier).
    Days paid: 1 * 3 = 3 ARK. Seconds owed: 1.5 * 3 = 4.5 ARK.
    The holder is short 1.5 ARK. The control divides the same elapsed
    seconds by 1 day and pays 4.5 ARK.
*/

contract Exploit {
    uint256 public constant LAST_TRANSFER = 1_700_000_000;
    uint256 public constant REWARD_PER_DAY = 3 ether;
    uint256 public constant BLOCK_TIME = 1_700_129_600;

    mapping(address => uint256) public balanceOf;

    uint256 public lastTransferTime;
    uint256 public elapsedSeconds;
    uint256 public daysHeld;
    uint256 public paid;
    uint256 public fair;
    uint256 public shortfall;

    function run() external {
        require(block.timestamp == BLOCK_TIME, "clock");
        lastTransferTime = LAST_TRANSFER;
        elapsedSeconds = block.timestamp - lastTransferTime;
        // @> VULN: whole days since the last transfer, not seconds
        daysHeld = elapsedSeconds / 1 days;
        paid = daysHeld * REWARD_PER_DAY;
        fair = elapsedSeconds * REWARD_PER_DAY / 1 days;
        shortfall = fair - paid;
        balanceOf[msg.sender] = paid;
        require(elapsedSeconds == 129_600, "elapsed");
        require(daysHeld == 1, "days");
        require(paid == 3 ether, "paid");
        require(fair == 4.5 ether, "fair");
        require(shortfall == 1.5 ether, "short");
        require(balanceOf[msg.sender] == paid, "mint");
        require(paid < fair, "underpaid");
    }
}

contract RewardSeconds {
    uint256 public constant LAST_TRANSFER = 1_700_000_000;
    uint256 public constant REWARD_PER_DAY = 3 ether;

    mapping(address => uint256) public balanceOf;
    uint256 public paid;

    function run() external {
        uint256 elapsedSeconds = block.timestamp - LAST_TRANSFER;
        paid = elapsedSeconds * REWARD_PER_DAY / 1 days;
        balanceOf[msg.sender] = paid;
    }
}
