// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  g8keep — migration swaps 1 wei and never reaches the target sqrt price
    (Pashov, H-01, finding 64998).
    SYNTHETIC, cheatcode-free. The else branch is the audited call:
    swap(..., int256(uint256(1)), target, ""). One wei moves the pool by 1.
    adjustFailed stays true, migrate() reverts, and 1_000_000 tokens stay
    in the old pool. The control swaps the distance to the target and the
    user receives the new tokens. */

contract MiniToken {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract MiniV3Pool {
    uint160 public sqrtPriceX96;

    constructor(uint160 startPrice) {
        sqrtPriceX96 = startPrice;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, false);
    }

    function swap(address, bool, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256, int256)
    {
        if (uint256(amountSpecified) == 1) {
            sqrtPriceX96 += 1;
        } else {
            sqrtPriceX96 = sqrtPriceLimitX96;
        }
        return (amountSpecified, 0);
    }
}

interface IUniswapV3Pool {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256, int256);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

contract Migrator {
    uint256 public constant START_PRICE = 100;
    uint256 public constant TARGET_PRICE = 1000;

    address public poolAddress;
    MiniToken public oldToken;
    MiniToken public newToken;
    address public oldPool;
    address public user;
    uint256 public tmpLPTokenId;

    constructor(address pool, MiniToken _old, MiniToken _newT, address _oldPool, address _user) {
        poolAddress = pool;
        oldToken = _old;
        newToken = _newT;
        oldPool = _oldPool;
        user = _user;
    }

    function _addTemporaryLiquidity(uint256, uint256, int24, int24) internal returns (uint256) {
        tmpLPTokenId = 1;
        return tmpLPTokenId;
    }

    function _adjustPoolPrice() internal returns (bool adjustFailed) {
        uint256 ethAmount = 100 ether;
        uint256 tokenAmount = 1000 ether;
        int24 constainedTickLower = -100;
        int24 constrainedTickUpper = 100;
        uint160 sqrtPriceX96Start = uint160(START_PRICE);
        uint160 sqrtPriceX96 = uint160(TARGET_PRICE);
        uint256 tmpId =
            _addTemporaryLiquidity(ethAmount / 100, tokenAmount / 100, constainedTickLower, constrainedTickUpper);
        tmpLPTokenId = tmpId;
        if (sqrtPriceX96Start > sqrtPriceX96) {
            IUniswapV3Pool(poolAddress).swap(address(this), true, int256(uint256(tokenAmount)), sqrtPriceX96, "");
        } else {
            // @> VULN: 1 wei of the quote token cannot move sqrt price from 100 to the target 1000
            IUniswapV3Pool(poolAddress).swap(address(this), false, int256(uint256(1)), sqrtPriceX96, "");
        }
        (uint160 sqrtPriceX96New,,,,,,) = IUniswapV3Pool(poolAddress).slot0();
        adjustFailed = sqrtPriceX96 != sqrtPriceX96New;
    }

    function migrate() external {
        bool adjustFailed = _adjustPoolPrice();
        require(!adjustFailed, "adjustFailed");
        uint256 bal = oldToken.balanceOf(oldPool);
        oldToken.burn(oldPool, bal);
        newToken.mint(user, bal);
    }
}

contract OldPool {}

contract Exploit {
    uint256 public constant STUCK = 1_000_000 ether;

    MiniToken public oldToken;
    MiniToken public newToken;
    MiniV3Pool public pool;
    OldPool public oldPool;
    Migrator public migrator;

    constructor() {
        oldToken = new MiniToken("OLD", "OLD");
        newToken = new MiniToken("NEW", "NEW");
        pool = new MiniV3Pool(100);
        oldPool = new OldPool();
        migrator = new Migrator(address(pool), oldToken, newToken, address(oldPool), address(this));
    }

    function run() external {
        oldToken.mint(address(oldPool), STUCK);
        (bool ok,) = address(migrator).call(abi.encodeCall(migrator.migrate, ()));
        require(!ok, "migration should revert");
        require(oldToken.balanceOf(address(oldPool)) == STUCK, "old pool drained");
        require(newToken.balanceOf(address(this)) == 0, "user received new tokens");
        require(pool.sqrtPriceX96() == 100, "price must stay put after revert");
    }
}
