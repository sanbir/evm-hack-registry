// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  EYWA GaugeV1 — notifyRewardAmount (MixBytes, AuditVault 44335)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: notifyRewardAmount builds the Merkl campaign from
    balanceOf(address(this)) and never transferFroms amount_.
    The gauge already holds 200 EYWA. The manager notifies 1,000
    and only approves. Stakers receive 200, not 1,000.
    Blamed lines copied verbatim (@> VULN). */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract EywaToken is IERC20 {
    string public name = "EYWA";
    string public symbol = "EYWA";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IDistributionCreator {
    struct CampaignParameters {
        uint256 amount;
        uint32 startTimestamp;
        uint32 duration;
    }

    function rewardTokenMinAmounts(address token) external view returns (uint256);
    function createCampaign(CampaignParameters memory params) external;
}

contract DistributionCreator is IDistributionCreator {
    EywaToken public eywa;
    address public staker;
    uint256 public lastAmount;

    constructor(EywaToken _eywa, address _staker) {
        eywa = _eywa;
        staker = _staker;
    }

    function rewardTokenMinAmounts(address) external pure returns (uint256) {
        return 1e18;
    }

    function createCampaign(CampaignParameters memory params) external {
        lastAmount = params.amount;
        eywa.transferFrom(msg.sender, staker, params.amount);
    }
}

contract GaugeV1 {
    error UnauthorizedCaller();

    uint256 public constant EPOCH_DURATION = 1 weeks;
    IDistributionCreator public DISTRIBUTION_CREATOR;
    address public s_escrowVoteManager;
    address public s_eywa;
    IDistributionCreator.CampaignParameters public s_campaignParameters;

    constructor(address eywa, IDistributionCreator creator, address manager) {
        s_eywa = eywa;
        DISTRIBUTION_CREATOR = creator;
        s_escrowVoteManager = manager;
    }

    function notifyRewardAmount(uint256 amount_) external {
        if (msg.sender != s_escrowVoteManager) {
            revert UnauthorizedCaller();
        }
        IERC20 m_eywa = IERC20(s_eywa);
        uint256 m_balance = m_eywa.balanceOf(address(this));
        if (m_balance * 1 hours / EPOCH_DURATION >= DISTRIBUTION_CREATOR.rewardTokenMinAmounts(address(m_eywa))) {
            m_eywa.approve(address(DISTRIBUTION_CREATOR), m_balance);
            IDistributionCreator.CampaignParameters memory m_campaignParameters = s_campaignParameters;
            // @> VULN: campaign amount is the gauge balance, not amount_, and amount_ is never transferFrom'd
            m_campaignParameters.amount = m_balance;
            m_campaignParameters.startTimestamp = uint32(block.timestamp);
            m_campaignParameters.duration = uint32(EPOCH_DURATION);
            DISTRIBUTION_CREATOR.createCampaign(m_campaignParameters);
        }
    }
}

contract Exploit {
    uint256 public constant NOTIFIED = 1000e18;
    uint256 public constant GAUGE_BALANCE = 200e18;
    address public constant STAKER = 0x000000000000000000000000000000000000bEEF;

    EywaToken public eywa; // CREATE nonce 1
    DistributionCreator public creator; // CREATE nonce 2
    GaugeV1 public gauge; // CREATE nonce 3

    uint256 public campaignAmount;
    uint256 public stakerReceived;
    uint256 public managerLeft;

    constructor() {
        eywa = new EywaToken();
        creator = new DistributionCreator(eywa, STAKER);
        gauge = new GaugeV1(address(eywa), creator, address(this));
        eywa.mint(address(gauge), GAUGE_BALANCE);
        eywa.mint(address(this), NOTIFIED);
    }

    function run() external {
        uint256 sitting = eywa.balanceOf(address(gauge));
        require(sitting == GAUGE_BALANCE, "gauge already holds 200");

        // The manager approves the notified 1,000 and does not transfer it.
        eywa.approve(address(gauge), NOTIFIED);
        gauge.notifyRewardAmount(NOTIFIED);

        campaignAmount = creator.lastAmount();
        stakerReceived = eywa.balanceOf(STAKER);
        managerLeft = eywa.balanceOf(address(this));
        require(campaignAmount == GAUGE_BALANCE, "campaign used 200");
        require(stakerReceived == GAUGE_BALANCE, "stakers received 200");
        require(managerLeft == NOTIFIED, "the notified 1000 never left the manager");
        require(stakerReceived != NOTIFIED, "stakers did not receive the notified 1000");
    }
}
