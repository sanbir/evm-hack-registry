// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC LendingPool — Cyfrin February 2025.
    _depositIntoVault records address(this) as the Curve vault share owner.
    _withdrawFromVault then passes msg.sender as owner. The vault spends the
    caller's allowance and balance, both zero, and reverts. The supplied
    liquidity stays in the vault. Passing address(this) as owner pays it out.
*/

contract Token {
    string public symbol = "crvUSD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CurveVault {
    Token public token;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(Token _token) {
        token = _token;
    }

    function deposit(uint256 amount, address owner) external returns (uint256) {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        sharesOf[owner] += amount;
        return amount;
    }

    function withdraw(uint256 amount, address receiver, address owner, uint256, address[] calldata)
        external
        returns (uint256)
    {
        if (msg.sender != owner) {
            require(allowance[owner][msg.sender] >= amount, "allowance");
            allowance[owner][msg.sender] -= amount;
        }
        require(sharesOf[owner] >= amount, "shares");
        sharesOf[owner] -= amount;
        require(token.transfer(receiver, amount), "pay");
        return amount;
    }
}

contract LendingPool {
    Token public token;
    CurveVault public curveVault;
    uint256 public totalVaultDeposits;
    mapping(address => uint256) public supplied;

    constructor(Token _token, CurveVault _vault) {
        token = _token;
        curveVault = _vault;
    }

    function _depositIntoVault(uint256 amount) internal {
        token.approve(address(curveVault), amount);
        curveVault.deposit(amount, address(this));
        totalVaultDeposits += amount;
    }

    function _withdrawFromVault(uint256 amount) internal {
        // @> VULN: owner is msg.sender, but the vault shares were minted to address(this)
        curveVault.withdraw(amount, address(this), msg.sender, 0, new address[](0));
        totalVaultDeposits -= amount;
    }

    function deposit(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        _depositIntoVault(amount);
        supplied[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        require(supplied[msg.sender] >= amount, "bal");
        _withdrawFromVault(amount);
        supplied[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "pay");
    }
}

contract LendingPoolFixed {
    Token public token;
    CurveVault public curveVault;
    mapping(address => uint256) public supplied;

    constructor(Token _token, CurveVault _vault) {
        token = _token;
        curveVault = _vault;
    }

    function deposit(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "pull");
        token.approve(address(curveVault), amount);
        curveVault.deposit(amount, address(this));
        supplied[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        require(supplied[msg.sender] >= amount, "bal");
        curveVault.withdraw(amount, address(this), address(this), 0, new address[](0));
        supplied[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "pay");
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100 ether;

    Token public token;
    CurveVault public vault;
    LendingPool public pool;
    bool public withdrawReverted;
    uint256 public stuck;

    constructor() {
        token = new Token();
        vault = new CurveVault(token);
        pool = new LendingPool(token, vault);
    }

    function run() external {
        token.mint(address(this), AMOUNT);
        token.approve(address(pool), AMOUNT);
        pool.deposit(AMOUNT);
        uint256 shares = vault.sharesOf(address(pool));
        (bool ok,) = address(pool).call(abi.encodeWithSelector(pool.withdraw.selector, AMOUNT));
        withdrawReverted = !ok;
        stuck = token.balanceOf(address(vault));
        require(shares == AMOUNT, "shares");
        require(vault.sharesOf(msg.sender) == 0, "user shares");
        require(withdrawReverted, "paid");
        require(token.balanceOf(address(this)) == 0, "user");
        require(stuck == AMOUNT, "stuck");
        require(pool.supplied(address(this)) == AMOUNT, "still supplied");
    }
}
