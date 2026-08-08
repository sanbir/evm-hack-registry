// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-04] Incorrect approval mechanism breaks all Magnetar
    functionality
    (carrotsmuggler, Code4rena 2024-02-tapioca, finding #32315)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: Magnetar still grants YieldBox / raw ERC20 approvals, but
    target markets (Singularity etc.) were refactored to pull tokens via
    pearlmit/permitC only. Magnetar never grants permitC, so every downstream
    transferFrom fails — bricking all Magnetar deposit/lend flows.

    Vulnerable approval path preserved (@> VULN): Magnetar sets YB approval;
    Singularity pulls via pearlmit only.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ERC20: insufficient allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal YieldBox share ledger + approval (what Magnetar still uses).
contract MockYieldBox {
    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    mapping(uint256 => mapping(address => mapping(address => bool))) public approved;

    function mint(uint256 assetId, address to, uint256 shares) external {
        balanceOf[assetId][to] += shares;
    }

    function setApprovalForAll(address spender, bool v) external {
        // simplified: one global approval flag per asset used below
        approved[0][msg.sender][spender] = v;
    }

    function transfer(address from, address to, uint256 assetId, uint256 shares) external {
        require(from == msg.sender || approved[0][from][msg.sender], "YB: not approved");
        balanceOf[assetId][from] -= shares;
        balanceOf[assetId][to] += shares;
    }
}

/// @dev Pearlmit/permitC stand-in: markets only accept this path.
contract Pearlmit {
    mapping(address => mapping(address => mapping(address => uint256))) public allowance;
    // owner => operator => token => amount

    function approve(address token, address operator, uint256 amount) external {
        allowance[msg.sender][operator][token] = amount;
    }

    function transferFrom(address token, address from, address to, uint256 amount) external {
        uint256 a = allowance[from][msg.sender][token];
        require(a >= amount, "Pearlmit: not approved");
        if (a != type(uint256).max) allowance[from][msg.sender][token] = a - amount;
        MockERC20(token).transferFrom(from, to, amount);
    }
}

/// @notice Singularity after the permitC refactor: only pulls via pearlmit.
contract Singularity {
    Pearlmit public pearlmit;
    MockERC20 public asset;
    mapping(address => uint256) public balanceOf;

    constructor(Pearlmit p, MockERC20 a) {
        pearlmit = p;
        asset = a;
    }

    function addAsset(address from, address to, uint256 amount) external {
        // Refactored path: transfer tokens via pearlmit, NOT YieldBox approval.
        pearlmit.transferFrom(address(asset), from, address(this), amount);
        balanceOf[to] += amount;
    }
}

/// @notice Magnetar still only grants YieldBox approval (broken).
contract Magnetar {
    MockYieldBox public yieldBox;
    Pearlmit public pearlmit;

    constructor(MockYieldBox yb, Pearlmit p) {
        yieldBox = yb;
        pearlmit = p;
    }

    /// @dev _depositYBLendSGL reduced: grants YB approval, then calls SGL.addAsset.
    function depositYBLendSGL(Singularity sgl, address user, uint256 amount) external returns (bool ok) {
        // FIX: pearlmit.approve(asset, singularity, amount) (or equivalent permitC grant)
        yieldBox.setApprovalForAll(address(sgl), true); // @> VULN: YB approval, but SGL uses pearlmit

        // No pearlmit approval is granted — so the call below reverts.
        try sgl.addAsset(address(this), user, amount) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    /// @dev Correct path (control): grant pearlmit so the same call succeeds.
    function depositYBLendSGLFixed(Singularity sgl, address user, uint256 amount) external returns (bool ok) {
        pearlmit.approve(address(sgl.asset()), address(sgl), amount);
        // SGL pulls from Magnetar via pearlmit; Magnetar must hold the ERC20 and
        // have approved pearlmit for transferFrom.
        sgl.asset().approve(address(pearlmit), amount);
        sgl.addAsset(address(this), user, amount);
        ok = true;
    }
}

contract Exploit {
    MockERC20 public asset; // 1
    MockYieldBox public yieldBox; // 2
    Pearlmit public pearlmit; // 3
    Singularity public sgl; // 4
    Magnetar public magnetar; // 5

    uint256 public constant AMOUNT = 100 ether;

    constructor() {
        asset = new MockERC20(); // 1
        yieldBox = new MockYieldBox(); // 2
        pearlmit = new Pearlmit(); // 3
        sgl = new Singularity(pearlmit, asset); // 4
        magnetar = new Magnetar(yieldBox, pearlmit); // 5

        // Magnetar holds the assets that should be lent into SGL.
        asset.mint(address(magnetar), AMOUNT);
        // Pearlmit needs ERC20 allowance from Magnetar for the fixed path; for
        // the buggy path it's irrelevant. Pre-approve for control later if needed.
        // Use a setup call: magnetar can't approve itself easily without a method —
        // for the fixed path we approve from magnetar via a helper in run.
    }

    function run() external {
        // Buggy Magnetar path: only YB approval → SGL pearlmit pull reverts.
        bool ok = magnetar.depositYBLendSGL(sgl, address(this), AMOUNT);
        require(!ok, "harm: Magnetar deposit must fail without pearlmit approval");
        require(sgl.balanceOf(address(this)) == 0, "no SGL credit");
        require(asset.balanceOf(address(magnetar)) == AMOUNT, "assets stuck on Magnetar");

        // Control: with pearlmit approval the same economic action succeeds.
        // Magnetar needs to ERC20-approve pearlmit; call via a thin wrapper:
        magnetar.depositYBLendSGLFixed(sgl, address(this), AMOUNT);
        require(sgl.balanceOf(address(this)) == AMOUNT, "control: SGL credited");
    }
}
