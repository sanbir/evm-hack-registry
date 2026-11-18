// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Regnum Aurum — yield is skimmed out of the curve-vault withdrawal (Pashov H-19, AuditVault 66181).
   SYNTHETIC, cheatcode-free. ensureLiquidity withdraws exactly the shortfall, then
   withdrawFromVault subtracts yield from that amount before forwarding crvUSD to the RToken.
   The RToken is 10 short of a 100 withdrawal, so the lender receives nothing. */

contract Cash {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract CurveVault {
    Cash public token;
    uint256 public price = 1.2 ether;

    constructor(Cash _token) {
        token = _token;
    }

    function pricePerShare(bool) external view returns (uint256) {
        return price;
    }

    function withdraw(uint256 assets, address, address) external returns (uint256 burnedShares) {
        burnedShares = assets * 1 ether / price;
        token.transfer(msg.sender, assets);
    }
}

contract RToken {
    Cash public token;

    constructor(Cash _token) {
        token = _token;
    }

    function pay(address to, uint256 amount) external {
        require(token.balanceOf(address(this)) >= amount, "RToken short");
        token.transfer(to, amount);
    }
}

contract LendingPool {
    Cash public token;
    CurveVault public vault;
    RToken public rtoken;
    uint256 public lastSharePrice = 1 ether;
    uint256 public unclaimedRewards;
    uint256 public maxWithdrawable = 1000 ether;

    constructor(Cash _token, CurveVault _vault, RToken _rtoken) {
        token = _token;
        vault = _vault;
        rtoken = _rtoken;
    }

    function ensureLiquidity(uint256 amount) external {
        uint256 availableLiquidity = token.balanceOf(address(rtoken));
        uint256 requiredAmount = amount - availableLiquidity;
        uint256 withdrawFromVaultAmount = requiredAmount;
        if (withdrawFromVaultAmount > maxWithdrawable) {
            withdrawFromVaultAmount = maxWithdrawable;
        }
        if (withdrawFromVaultAmount > 0) {
            withdrawFromVault(withdrawFromVaultAmount);
        }
    }

    function withdrawFromVault(uint256 amount) internal {
        uint256 currentSharePrice = vault.pricePerShare(true);
        uint256 burnedShares = vault.withdraw(amount, address(this), address(this));

        uint256 yield;
        if (currentSharePrice > lastSharePrice) {
            uint256 priceDiff = currentSharePrice - lastSharePrice;
            yield = (burnedShares * priceDiff) / 1 ether; // @> VULN: yield is taken out of the assets just withdrawn for the lender
            unclaimedRewards += yield;
        } else {
            yield = 0;
        }
        uint256 transferAmount = amount - yield;
        token.transfer(address(rtoken), transferAmount);
    }
}

contract Exploit {
    Cash public token; // nonce 1
    CurveVault public curve; // nonce 2
    RToken public rtoken; // nonce 3
    LendingPool public pool; // nonce 4
    address public constant LENDER = address(uint160(0x1E4D));
    bool public withdrawFailed;
    uint256 public rtokenBal;
    uint256 public lenderBal;
    uint256 public skimmed;

    constructor() {
        token = new Cash();
        curve = new CurveVault(token);
        rtoken = new RToken(token);
        pool = new LendingPool(token, curve, rtoken);
    }

    function run() external {
        token.mint(address(rtoken), 40 ether);
        token.mint(address(curve), 60 ether);
        pool.ensureLiquidity(100 ether);
        try rtoken.pay(LENDER, 100 ether) {
            withdrawFailed = false;
        } catch {
            withdrawFailed = true;
        }
        rtokenBal = token.balanceOf(address(rtoken));
        lenderBal = token.balanceOf(LENDER);
        skimmed = pool.unclaimedRewards();
        require(withdrawFailed, "withdrawal paid");
        require(lenderBal == 0, "lender received crvUSD");
        require(rtokenBal == 90 ether, "rtoken");
        require(skimmed == 10 ether, "yield skim");
        require(token.balanceOf(address(pool)) == 10 ether, "skim sits in the pool");
    }
}
