// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  g8keep — migration swaps 1 wei and never reaches the target price (Pashov, finding #45306)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _adjustPoolPrice pushes the Uniswap V3 price up with a hardcoded 1 wei swap.
    That amount stops at the constrained tick. adjustFailed stays true and the token inventory
    is never moved into the pool. Vulnerable line preserved verbatim below (@> VULN). */

contract MigToken {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract UniPool {
    uint160 public price;
    uint160 public constrainedUpper;

    constructor(uint160 startPrice) {
        price = startPrice;
        constrainedUpper = startPrice + 1;
    }

    function swap(address, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256 amount0, int256 amount1)
    {
        uint256 amt = uint256(amountSpecified);
        if (!zeroForOne) {
            if (amt == 1) {
                price = constrainedUpper;
            } else if (price + uint160(amt) >= sqrtPriceLimitX96) {
                price = sqrtPriceLimitX96;
            } else {
                price += uint160(amt);
            }
        } else if (amt >= price) {
            price = sqrtPriceLimitX96;
        } else {
            price -= uint160(amt);
        }
        amount0 = amountSpecified;
        amount1 = amountSpecified;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (price, 0, 0, 0, 0, 0, true);
    }
}

contract Migrator {
    MigToken public token;
    UniPool public pool;
    uint160 public constant START_PRICE = 1000;
    uint160 public constant TARGET_PRICE = 5000;
    uint256 public temporaryLiquidity;
    uint256 public lastTmpLp;
    bool public adjustFailed;
    bool public migrated;
    int24 public constainedTickLower = 1000;
    int24 public constrainedTickUpper = 1001;

    constructor(MigToken _token, UniPool _pool) {
        token = _token;
        pool = _pool;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function migrate() external {
        bool failed = _adjustPoolPrice();
        adjustFailed = failed;
        if (failed) return;
        uint256 bal = token.balanceOf(address(this));
        token.transfer(address(pool), bal);
        migrated = true;
    }

    function _addTemporaryLiquidity(uint256 ethAmt, uint256 tokenAmt, int24, int24)
        internal
        returns (uint256 tmpLPTokenId)
    {
        temporaryLiquidity = ethAmt + tokenAmt;
        tmpLPTokenId = 1;
    }

    function _adjustPoolPrice() internal returns (bool adjustFailed_) {
        uint256 ethAmount = 100 ether;
        uint256 tokenAmount = 1000 ether;
        uint160 sqrtPriceX96Start = pool.price();
        uint160 sqrtPriceX96 = TARGET_PRICE;
        uint256 tmpLPTokenId =
            _addTemporaryLiquidity(ethAmount / 100, tokenAmount / 100, constainedTickLower, constrainedTickUpper);
        lastTmpLp = tmpLPTokenId;
        if (sqrtPriceX96Start > sqrtPriceX96) {
            pool.swap(address(this), true, int256(uint256(tokenAmount)), sqrtPriceX96, "");
        } else {
            // @> VULN: 1 wei stops at constrainedTickUpper and cannot reach sqrtPriceX96
            pool.swap(address(this), false, int256(uint256(1)), sqrtPriceX96, "");
        }
        (uint160 sqrtPriceX96New,,,,,,) = pool.slot0();
        adjustFailed_ = sqrtPriceX96 != sqrtPriceX96New;
    }
}

contract MigratorFixed {
    MigToken public token;
    UniPool public pool;
    uint160 public constant TARGET_PRICE = 5000;
    bool public adjustFailed;
    bool public migrated;
    int24 public constainedTickLower = 1000;
    int24 public constrainedTickUpper = 1001;

    constructor(MigToken _token, UniPool _pool) {
        token = _token;
        pool = _pool;
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function migrate() external {
        bool failed = _adjustPoolPrice();
        adjustFailed = failed;
        if (failed) return;
        uint256 bal = token.balanceOf(address(this));
        token.transfer(address(pool), bal);
        migrated = true;
    }

    uint256 public temporaryLiquidity;

    function _addTemporaryLiquidity(uint256 ethAmt, uint256 tokenAmt, int24, int24) internal returns (uint256) {
        temporaryLiquidity = ethAmt + tokenAmt;
        return 1;
    }

    function _adjustPoolPrice() internal returns (bool adjustFailed_) {
        uint256 ethAmount = 100 ether;
        uint256 tokenAmount = 1000 ether;
        uint160 sqrtPriceX96Start = pool.price();
        uint160 sqrtPriceX96 = TARGET_PRICE;
        _addTemporaryLiquidity(ethAmount / 100, tokenAmount / 100, constainedTickLower, constrainedTickUpper);
        uint256 needed = uint256(sqrtPriceX96 - sqrtPriceX96Start);
        if (sqrtPriceX96Start > sqrtPriceX96) {
            pool.swap(address(this), true, int256(uint256(tokenAmount)), sqrtPriceX96, "");
        } else {
            pool.swap(address(this), false, int256(needed), sqrtPriceX96, "");
        }
        (uint160 sqrtPriceX96New,,,,,,) = pool.slot0();
        adjustFailed_ = sqrtPriceX96 != sqrtPriceX96New;
    }
}

contract Exploit {
    MigToken public token; // CREATE nonce 1
    UniPool public pool; // CREATE nonce 2
    Migrator public migrator; // CREATE nonce 3

    constructor() {
        token = new MigToken();
        pool = new UniPool(1000);
        migrator = new Migrator(token, pool);
    }

    function run() external {
        token.mint(address(this), 1000 ether);
        token.transfer(address(migrator), 1000 ether);
        migrator.migrate();
        require(migrator.adjustFailed(), "price not reached");
        require(!migrator.migrated(), "migrated");
        require(token.balanceOf(address(migrator)) == 1000 ether, "tokens stuck");
        require(pool.price() == pool.constrainedUpper(), "stopped at tick");
        require(pool.price() != migrator.TARGET_PRICE(), "hit target");
    }
}
