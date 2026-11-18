// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Burve — ERC4626ViewAdjustor swaps toNominal and toReal (Sherlock H-2, finding 56951)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: toReal calls convertToAssets and toNominal calls convertToShares.
    At 1 stETH = 1.1 ETH, a 100 nominal deposit is charged 110 stETH instead of
    90.909090909090909090 stETH. The uncredited 19.090909090909090910 stETH stays
    in the surplus holder. Vulnerable line preserved verbatim (@> VULN). */

contract MockToken {
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// 1 share = 1.1 assets, matching the report's stETH/WETH example.
contract MockVault {
    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets * 1000 / 1100;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares * 1100 / 1000;
    }
}

contract ERC4626ViewAdjustor {
    MockVault public vault;

    constructor(MockVault v) {
        vault = v;
    }

    function getVault(address) public view returns (MockVault) {
        return vault;
    }

    function toNominal(address token, uint256 real, bool) external view returns (uint256) {
        return getVault(token).convertToShares(real); // reversed: nominal value of real shares is convertToAssets
        // FIX: return getVault(token).convertToAssets(real);
    }

    function toReal(address token, uint256 nominal, bool) external view returns (uint256) {
        return getVault(token).convertToAssets(nominal); // @> VULN: toReal must be convertToShares; this charges 110 stETH for 100 nominal
        // FIX: return getVault(token).convertToShares(nominal);
    }
}

contract FixedAdjustor {
    MockVault public vault;

    constructor(MockVault v) {
        vault = v;
    }

    function toReal(address, uint256 nominal, bool) external view returns (uint256) {
        return vault.convertToShares(nominal);
    }
}

contract Surplus {}

contract Pool {
    MockToken public token;
    ERC4626ViewAdjustor public adjustor;
    Surplus public surplus;
    uint256 public credited;

    constructor(MockToken t, ERC4626ViewAdjustor a, Surplus s) {
        token = t;
        adjustor = a;
        surplus = s;
    }

    function deposit(uint256 nominal) external returns (uint256 charged, uint256 fair) {
        charged = adjustor.toReal(address(token), nominal, false); // S2
        fair = nominal * 1000 / 1100;
        token.transferFrom(msg.sender, address(this), charged); // S4
        uint256 excess = charged - fair;
        token.transfer(address(surplus), excess); // S5
        credited = fair;
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    MockVault public vault; // nonce 2
    ERC4626ViewAdjustor public adjustor; // nonce 3
    Surplus public surplus; // nonce 4
    Pool public pool; // nonce 5

    uint256 public constant NOMINAL = 100 ether;
    uint256 public charged;
    uint256 public fair;
    uint256 public excess;

    constructor() {
        token = new MockToken();
        vault = new MockVault();
        adjustor = new ERC4626ViewAdjustor(vault);
        surplus = new Surplus();
        pool = new Pool(token, adjustor, surplus);
        token.mint(address(this), 110 ether);
        token.approve(address(pool), type(uint256).max);
    }

    function run() external {
        (charged, fair) = pool.deposit(NOMINAL); // S1
        excess = token.balanceOf(address(surplus)); // S6
        require(charged == 110 ether, "charged");
        require(fair == 90909090909090909090, "fair");
        require(excess == 19090909090909090910, "depositor overpaid");
        require(pool.credited() == fair, "credit");
        require(token.balanceOf(address(this)) == 0, "user drained");
    }
}
