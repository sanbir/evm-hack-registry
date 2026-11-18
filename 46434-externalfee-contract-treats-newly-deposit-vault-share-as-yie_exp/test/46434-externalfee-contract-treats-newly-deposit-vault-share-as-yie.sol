// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Balmy — ExternalFee treats a direct vault-share deposit as yield (Cantina, 46434)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: the user transfers ERC-4626 shares straight to the strategy, then
    _fees_deposited snapshots balanceOf, which already includes that transfer.
    A 500 bps performance fee is charged on the deposit itself. Line preserved (@> VULN). */

contract Share {
    string public name = "Vault Share";
    string public symbol = "vSHARE";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }
}

contract ExternalFeeStrategy {
    uint256 public constant PERFORMANCE_FEE = 500; // 5%
    Share public shares;
    address public feeRecipient;
    uint256 public lastBalance;
    uint256 public performanceFees;
    bool public isSet;
    uint256 public lastCredited;

    constructor(Share _shares, address _feeRecipient) {
        shares = _shares;
        feeRecipient = _feeRecipient;
    }

    function depositShares(uint256 depositAmount) external returns (uint256 credited) {
        require(shares.transferFrom(msg.sender, address(this), depositAmount), "pull"); // STORY2
        uint256 assetsDeposited = _fees_deposited(address(shares), depositAmount);
        credited = assetsDeposited - performanceFees;
        lastCredited = credited; // STORY6
    }

    /// Underlying-asset path. The balance snapshot is taken before shares exist, so the fee is 0.
    function depositAsset(uint256 depositAmount) external returns (uint256 credited) {
        uint256 current = shares.balanceOf(address(this));
        uint256 fee = _calculateFees(current, PERFORMANCE_FEE);
        shares.mint(address(this), depositAmount);
        performanceFees = fee;
        credited = depositAmount - fee;
        lastCredited = credited;
    }

    function _fees_deposited(address, uint256 depositAmount) internal returns (uint256 assetsDeposited) {
        uint256 performanceFeeBps = PERFORMANCE_FEE;
        if (performanceFeeBps == 0) {
            lastBalance = 0;
            isSet = false;
            return depositAmount;
        }
        uint256 currentBalance = shares.balanceOf(address(this)); // STORY3 deposit already included
        uint256 performanceFee = _calculateFees(currentBalance, performanceFeeBps); // @> VULN: deposit counted as yield
        // FIX: snapshot the balance before the user's transfer, and fee only the increase above that
        assetsDeposited = depositAmount;
        lastBalance = currentBalance + assetsDeposited; // STORY5 also double-counts the deposit
        performanceFees = performanceFee;
        isSet = true;
        if (performanceFee > 0) require(shares.transfer(feeRecipient, performanceFee), "skim"); // STORY4
    }

    function _calculateFees(uint256 current, uint256 bps) internal view returns (uint256) {
        uint256 baseline = isSet ? lastBalance : 0;
        if (current <= baseline) return 0;
        return (current - baseline) * bps / 10_000;
    }
}

contract Exploit {
    Share public shares; // nonce 1
    ExternalFeeStrategy public strategy; // nonce 2
    address public feeRecipient; // nonce 3, a bare recipient contract
    uint256 public constant DEPOSIT = 100_000 ether;

    constructor() {
        shares = new Share();
        feeRecipient = address(new FeeRecipient());
        strategy = new ExternalFeeStrategy(shares, feeRecipient);
        shares.mint(address(this), DEPOSIT);
    }

    function run() external {
        require(shares.approve(address(strategy), DEPOSIT), "ap");
        uint256 credited = strategy.depositShares(DEPOSIT); // STORY1
        require(credited == 95_000 ether, "credited");
        require(strategy.lastCredited() == 95_000 ether, "stored");
        require(shares.balanceOf(feeRecipient) == 5_000 ether, "fee");
        require(shares.balanceOf(address(strategy)) == 95_000 ether, "left");
        require(strategy.performanceFees() == 5_000 ether, "fee var");
    }
}

contract FeeRecipient {}
