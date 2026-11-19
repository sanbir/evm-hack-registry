// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// AuditVault 51947 - Bonzo LendingPool.withdraw for WHBAR.
// burn sends `amount` of WHBAR to `to`, then the pool unwraps another `amount`
// of WHBAR taken from msg.sender. `to` is paid twice. The caller loses 100 ether
// of wallet WHBAR on top of the aToken burn.

contract ERC20Mini {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

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

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract LendingPool {
    ERC20Mini public whbar;
    ERC20Mini public hbar;
    mapping(address => uint256) public aBalance;
    uint256 public extraPaid;

    constructor(ERC20Mini w, ERC20Mini h) {
        whbar = w;
        hbar = h;
    }

    function bootstrap(address user, uint256 amount) external {
        aBalance[user] = amount;
    }

    function withdraw(uint256 amount, address to) external {
        uint256 underlyingOut = amount; // S:out
        aBalance[msg.sender] -= underlyingOut; // S:debt
        whbar.transfer(to, underlyingOut); // S:burn
        uint256 second = amount; // S:second
        // @> VULN: unwrap pulls a second `amount` from the caller and pays `to` again
        whbar.transferFrom(msg.sender, address(this), second); // S:vuln
        hbar.transfer(to, second); // S:hbar
        extraPaid += second; // S:extra
    }
}

contract LendingPoolFixed {
    ERC20Mini public whbar;
    ERC20Mini public hbar;
    mapping(address => uint256) public aBalance;

    constructor(ERC20Mini w, ERC20Mini h) {
        whbar = w;
        hbar = h;
    }

    function bootstrap(address user, uint256 amount) external {
        aBalance[user] = amount;
    }

    function withdraw(uint256 amount, address to) external {
        aBalance[msg.sender] -= amount;
        // Burn underlying to this contract (it already holds the reserve), unwrap once.
        hbar.transfer(to, amount);
    }
}

contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 public constant AMOUNT = 100 ether;

    ERC20Mini public whbar;
    ERC20Mini public hbar;
    LendingPool public pool;

    function run() external {
        whbar = new ERC20Mini("WHBAR");
        hbar = new ERC20Mini("HBAR");
        pool = new LendingPool(whbar, hbar);
        whbar.mint(address(pool), AMOUNT);
        hbar.mint(address(pool), AMOUNT);
        whbar.mint(address(this), AMOUNT);
        whbar.approve(address(pool), AMOUNT);
        pool.bootstrap(address(this), AMOUNT);
        pool.withdraw(AMOUNT, SINK);
    }
}
