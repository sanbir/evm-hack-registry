// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Harmonix FundContract — management fee uses the setup clock (Shieldify H-02, finding 57887)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    setupVaultSetting stores the harvest timestamp at vault setup. The fee period is
    timestamp - that setup time, so a deposit 30 days later is charged for 31 days.
    The fair period is the 1 day the assets were actually deposited.
    Charged 84931528320000000000. Fair 2739726720000000000. Extra 82191801600000000000.
    The blamed period assignment is preserved (@> VULN). run() does not warp. */

contract MockToken {
    string public name = "Fund Asset";
    string public symbol = "ASSET";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FundContract {
    uint256 internal constant YEAR = 365 * 86400;

    MockToken public token;
    address public feeReceiver;
    uint256 public managementFeeRate;
    uint256 public lastHarvestManagementFeeTime;
    uint256 public lastHarvestPerformanceFeeTime;
    uint256 public depositTime;
    uint256 public nav;
    uint256 public chargedPeriod;
    uint256 public charged;

    constructor(address token_) {
        token = MockToken(token_);
    }

    // Quoted setup stores block.timestamp in both harvest fields. The caller passes that timestamp.
    function setupVaultSetting(uint256 setupTimestamp, uint256 rate, address feeTo) external {
        managementFeeRate = rate;
        feeReceiver = feeTo;
        lastHarvestManagementFeeTime = setupTimestamp;
        lastHarvestPerformanceFeeTime = setupTimestamp;
    }

    function deposit(uint256 amount, uint256 whenDeposited) external {
        nav = amount;
        depositTime = whenDeposited;
        token.mint(address(this), amount);
    }

    // fundContract.sol _calculateManagementFeeAmount
    function _calculateManagementFeeAmount(uint256 timestamp, uint256 navAmount) public returns (uint256) {
        uint256 perSecondRate = (managementFeeRate * 1e12) / YEAR + 1;
        // @> VULN: period runs from vault setup, not from the moment funds were deposited
        chargedPeriod = timestamp - lastHarvestManagementFeeTime;
        // FIX: subtract the first-deposit timestamp instead of the setup timestamp
        return (navAmount * perSecondRate * chargedPeriod) / 1e14;
    }

    function harvest(uint256 timestamp) external returns (uint256 fee) {
        fee = _calculateManagementFeeAmount(timestamp, nav);
        charged = fee;
        token.transfer(feeReceiver, fee);
    }

    function fairFee(uint256 timestamp) public view returns (uint256) {
        uint256 perSecondRate = (managementFeeRate * 1e12) / YEAR + 1;
        uint256 period = timestamp - depositTime;
        return (nav * perSecondRate * period) / 1e14;
    }
}

contract FundFixed {
    uint256 internal constant YEAR = 365 * 86400;

    MockToken public token;
    address public feeReceiver;
    uint256 public managementFeeRate;
    uint256 public lastHarvestManagementFeeTime;
    uint256 public nav;

    constructor(address token_) {
        token = MockToken(token_);
    }

    function setupVaultSetting(uint256 setupTimestamp, uint256 rate, address feeTo) external {
        managementFeeRate = rate;
        feeReceiver = feeTo;
        setupTimestamp;
    }

    function deposit(uint256 amount, uint256 whenDeposited) external {
        nav = amount;
        lastHarvestManagementFeeTime = whenDeposited;
        token.mint(address(this), amount);
    }

    function harvest(uint256 timestamp) external returns (uint256 fee) {
        uint256 perSecondRate = (managementFeeRate * 1e12) / YEAR + 1;
        uint256 period = timestamp - lastHarvestManagementFeeTime;
        fee = (nav * perSecondRate * period) / 1e14;
        token.transfer(feeReceiver, fee);
    }
}

contract Exploit {
    address public constant FEE = 0x0000000000000000000000000000000000000B0b;
    uint256 public constant NOW = 1_700_000_000;
    uint256 public constant NAV = 1000 ether;
    uint256 public constant CHARGED = 84931528320000000000;
    uint256 public constant FAIR = 2739726720000000000;

    MockToken public token;
    FundContract public fund;
    uint256 public charged;
    uint256 public fair;
    uint256 public extra;
    uint256 public period;

    constructor() {
        token = new MockToken();
        fund = new FundContract(address(token));
    }

    function run() external {
        uint256 setupTime = NOW - 31 days;
        uint256 depositedAt = NOW - 1 days;
        fund.setupVaultSetting(setupTime, 100, FEE);
        fund.deposit(NAV, depositedAt);
        charged = fund.harvest(NOW);
        fair = fund.fairFee(NOW);
        period = fund.chargedPeriod();
        extra = charged - fair;
        require(period == 31 days, "period is not 31 days");
        require(charged == CHARGED, "charged fee");
        require(fair == FAIR, "fair fee");
        require(extra == CHARGED - FAIR, "extra fee");
        require(token.balanceOf(FEE) == CHARGED, "fee receiver");
        require(depositedAt - setupTime == 30 days, "setup leads the deposit by 30 days");
    }
}
