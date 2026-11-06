// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, MiniToken} from "./31548-h-03-workers-could-withdraw-without-deregister-and-waiting-f.sol";

contract WorkerRegistrationFixed {
    struct Worker {
        address creator;
        uint256 bond;
        uint128 registeredAt;
        uint128 deregisteredAt;
    }

    MiniToken public tSQD;
    uint256 private workerIdTracker;
    mapping(uint256 => Worker) public workers;
    mapping(bytes peerId => uint256 id) public workerIds;
    uint256[] public activeWorkerIds;

    constructor(address _tSQD) {
        tSQD = MiniToken(_tSQD);
    }

    function register(bytes calldata peerId) external {
        workerIdTracker++;
        uint256 workerId = workerIdTracker;
        workers[workerId] = Worker({
            creator: msg.sender,
            bond: 1000e18,
            registeredAt: uint128(block.number + 1000),
            deregisteredAt: 0
        });
        workerIds[peerId] = workerId;
        activeWorkerIds.push(workerId);
        tSQD.transferFrom(msg.sender, address(this), 1000e18);
    }

    function withdraw(bytes calldata peerId) external {
        uint256 workerId = workerIds[peerId];
        Worker storage worker = workers[workerId];
        require(worker.creator == msg.sender, "Not worker creator");
        require(worker.deregisteredAt != 0, "Worker is locked");
        require(block.number >= worker.deregisteredAt + 1000, "Worker is locked");
        uint256 bond = worker.bond;
        delete workers[workerId];
        tSQD.transfer(msg.sender, bond);
    }
}

contract Finding31548Test is Test {
    function test_exploit_withdraws_before_lock_and_leaves_ghost_ids() public {
        Exploit e = new Exploit();
        vm.roll(176329477);
        e.run();
        assertEq(e.tSQD().balanceOf(address(e)), e.BOND(), "bond returned same tx");
        assertEq(e.tSQD().balanceOf(address(e.reg())), 0, "nothing left locked");
        assertEq(e.reg().activeWorkerCount(), 2, "two ghost ids");
        (address creator,,,,) = e.reg().workers(1);
        assertEq(creator, address(0), "worker struct deleted");
        assertEq(e.reg().activeWorkerIds(0), 1, "id 1 still listed");
        assertEq(e.reg().activeWorkerIds(1), 2, "id 2 still listed");
    }

    function test_control_requires_deregister_before_withdraw() public {
        MiniToken tSQD = new MiniToken("Subsquid", "SQD");
        WorkerRegistrationFixed reg = new WorkerRegistrationFixed(address(tSQD));
        tSQD.mint(address(this), 1000e18);
        tSQD.approve(address(reg), type(uint256).max);
        vm.roll(176329477);
        reg.register(bytes("worker-1"));
        vm.expectRevert(bytes("Worker is locked"));
        reg.withdraw(bytes("worker-1"));
        assertEq(tSQD.balanceOf(address(reg)), 1000e18, "bond stays locked");
        assertEq(reg.activeWorkerIds(0), 1, "still a live registration");
    }
}
