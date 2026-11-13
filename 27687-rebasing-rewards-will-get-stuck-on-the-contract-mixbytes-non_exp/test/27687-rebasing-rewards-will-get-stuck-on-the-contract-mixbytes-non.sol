// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Curve StableSwap-NG — stored_balances is not increased when a rebasing
    coin accrues (MixBytes, CurveStableSwapNG._transfer_out).
    remove_liquidity pays the live balance, then subtracts that live amount
    from the smaller stored balance. The subtraction underflows and the
    withdrawal reverts, so principal and rewards stay in the pool.
    Syncing stored_balances up to the live balance before the subtraction
    lets the LP take both. */

contract RebaseCoin27687 {
    string public name = "stETH";
    string public symbol = "stETH";
    uint8 public decimals = 18;
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

contract StablePool27687 {
    RebaseCoin27687 public coin;
    uint256 public storedBalances;
    uint256 public lpSupply;
    mapping(address => uint256) public lpOf;
    bool public syncRewards;

    constructor(RebaseCoin27687 c, bool sync) {
        coin = c;
        syncRewards = sync;
    }

    function deposit(address lp, uint256 amount) external {
        storedBalances += amount;
        lpSupply += amount;
        lpOf[lp] += amount;
    }

    function removeLiquidity(address lp) external returns (uint256 value) {
        uint256 burn = lpOf[lp];
        uint256 live = coin.balanceOf(address(this));
        if (syncRewards && live > storedBalances) {
            storedBalances = live;
        }
        value = live * burn / lpSupply;
        coin.transfer(lp, value);
        // @> VULN: stored_balances ignores the rebase. Subtracting the live withdrawal underflows, so the whole removal reverts.
        storedBalances -= value;
        lpOf[lp] = 0;
        lpSupply -= burn;
    }
}

contract Exploit {
    uint256 public constant PRINCIPAL = 1000 ether;
    uint256 public constant REWARD = 100 ether;

    RebaseCoin27687 public coin;
    StablePool27687 public pool;
    RebaseCoin27687 public coinC;
    StablePool27687 public poolC;

    uint256 public deposited;
    uint256 public storedBefore;
    uint256 public liveBefore;
    bool public removeReverted;
    uint256 public stuck;
    uint256 public lpGot;
    uint256 public controlGot;
    uint256 public controlLeft;

    function run() external {
        coin = new RebaseCoin27687();
        pool = new StablePool27687(coin, false);
        coinC = new RebaseCoin27687();
        poolC = new StablePool27687(coinC, true);

        coin.mint(address(pool), PRINCIPAL);
        pool.deposit(address(this), PRINCIPAL);
        coin.mint(address(pool), REWARD);
        deposited = PRINCIPAL;
        storedBefore = pool.storedBalances();
        liveBefore = coin.balanceOf(address(pool));

        try pool.removeLiquidity(address(this)) {
            removeReverted = false;
        } catch {
            removeReverted = true;
        }
        stuck = coin.balanceOf(address(pool));
        lpGot = coin.balanceOf(address(this));

        coinC.mint(address(poolC), PRINCIPAL);
        poolC.deposit(address(this), PRINCIPAL);
        coinC.mint(address(poolC), REWARD);
        controlGot = poolC.removeLiquidity(address(this));
        controlLeft = coinC.balanceOf(address(poolC));

        require(storedBefore == PRINCIPAL, "stored");
        require(liveBefore == PRINCIPAL + REWARD, "live");
        require(removeReverted, "reverted");
        require(stuck == PRINCIPAL + REWARD, "stuck");
        require(lpGot == 0, "lp");
        require(controlGot == PRINCIPAL + REWARD, "control got");
        require(controlLeft == 0, "control left");
        require(coinC.balanceOf(address(this)) == PRINCIPAL + REWARD, "control lp");
    }
}
