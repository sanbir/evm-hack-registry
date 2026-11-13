// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Flayer Locker / UniswapImplementation (Sherlock 2024-08, finding 41746)
    initializeCollection is the only PoolManager.unlock. The callback adds
    liquidity and PoolManager credits msg.sender, which is the implementation.
    There is no remove path. 10 WETH and 10 collection tokens stay in the pool.
    A different peripheral cannot pull them because it is not the position owner.

    CREATE order inside Exploit:
      nonce 1 Weth, 2 Collection, 3 PoolManager, 4 UniswapImplementation,
      5 Locker, 6 Peripheral
*/

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

contract PoolManager {
    Erc20 public weth;
    Erc20 public col;
    mapping(address => uint256) public liquidityOf;
    mapping(address => uint256) public held0;
    mapping(address => uint256) public held1;

    constructor(Erc20 _weth, Erc20 _col) {
        weth = _weth;
        col = _col;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlock(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(int256 liquidityDelta, uint256 amount0, uint256 amount1) external {
        if (liquidityDelta > 0) {
            address owner = msg.sender;
            liquidityOf[owner] += uint256(liquidityDelta);
            weth.transferFrom(owner, address(this), amount0);
            col.transferFrom(owner, address(this), amount1);
            held0[owner] += amount0;
            held1[owner] += amount1;
        } else {
            uint256 take = uint256(-liquidityDelta);
            require(liquidityOf[msg.sender] >= take, "not owner");
            liquidityOf[msg.sender] -= take;
            uint256 a0 = held0[msg.sender];
            uint256 a1 = held1[msg.sender];
            held0[msg.sender] = 0;
            held1[msg.sender] = 0;
            weth.transfer(msg.sender, a0);
            col.transfer(msg.sender, a1);
        }
    }
}

interface IUnlock {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

contract UniswapImplementation {
    PoolManager public pool;
    address public locker;
    Erc20 public weth;
    Erc20 public col;
    error CallerIsNotLocker();

    constructor(PoolManager _pool, Erc20 _weth, Erc20 _col) {
        pool = _pool;
        weth = _weth;
        col = _col;
    }

    function setLocker(address _locker) external {
        require(locker == address(0), "set");
        locker = _locker;
    }

    function initializeCollection(uint256 _amount0, uint256 _amount1) external {
        if (msg.sender != locker) revert CallerIsNotLocker();
        weth.approve(address(pool), _amount0);
        col.approve(address(pool), _amount1);
        // @> VULN: the only PoolManager.unlock. Liquidity is credited to this contract and never removed
        pool.unlock(abi.encode(_amount0, _amount1));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pool), "lock");
        (uint256 amount0, uint256 amount1) = abi.decode(data, (uint256, uint256));
        int256 liquidityDelta = int256(uint256(amount0));
        pool.modifyLiquidity(liquidityDelta, amount0, amount1);
        return "";
    }
}

contract Locker {
    UniswapImplementation public impl;
    Erc20 public weth;
    Erc20 public col;

    constructor(UniswapImplementation _impl, Erc20 _weth, Erc20 _col) {
        impl = _impl;
        weth = _weth;
        col = _col;
    }

    function initializeCollection(uint256 amount0, uint256 amount1) external {
        weth.transferFrom(msg.sender, address(impl), amount0);
        col.transferFrom(msg.sender, address(impl), amount1);
        impl.initializeCollection(amount0, amount1);
    }
}

contract Peripheral {
    PoolManager public pool;

    constructor(PoolManager _pool) {
        pool = _pool;
    }

    function pull() external {
        pool.modifyLiquidity(-1 ether, 0, 0);
    }
}

contract PoolManagerFixed {
    Erc20 public weth;
    Erc20 public col;
    mapping(address => uint256) public liquidityOf;
    mapping(address => uint256) public held0;
    mapping(address => uint256) public held1;

    constructor(Erc20 _weth, Erc20 _col) {
        weth = _weth;
        col = _col;
    }

    function modifyLiquidity(int256 liquidityDelta, uint256 amount0, uint256 amount1) external {
        if (liquidityDelta > 0) {
            liquidityOf[msg.sender] += uint256(liquidityDelta);
            weth.transferFrom(msg.sender, address(this), amount0);
            col.transferFrom(msg.sender, address(this), amount1);
            held0[msg.sender] += amount0;
            held1[msg.sender] += amount1;
        } else {
            require(liquidityOf[msg.sender] > 0, "not owner");
            liquidityOf[msg.sender] = 0;
            uint256 a0 = held0[msg.sender];
            uint256 a1 = held1[msg.sender];
            held0[msg.sender] = 0;
            held1[msg.sender] = 0;
            weth.transfer(msg.sender, a0);
            col.transfer(msg.sender, a1);
        }
    }
}

contract ImplementationFixed {
    PoolManagerFixed public pool;
    Erc20 public weth;
    Erc20 public col;
    address public depositor;
    uint256 public deposited0;

    constructor(PoolManagerFixed _pool, Erc20 _weth, Erc20 _col) {
        pool = _pool;
        weth = _weth;
        col = _col;
    }

    function initializeCollection(uint256 amount0, uint256 amount1) external {
        depositor = msg.sender;
        deposited0 = amount0;
        weth.transferFrom(msg.sender, address(this), amount0);
        col.transferFrom(msg.sender, address(this), amount1);
        weth.approve(address(pool), amount0);
        col.approve(address(pool), amount1);
        pool.modifyLiquidity(int256(amount0), amount0, amount1);
    }

    function removeLiquidity() external {
        require(msg.sender == depositor, "dep");
        pool.modifyLiquidity(-int256(deposited0), deposited0, 0);
        weth.transfer(depositor, weth.balanceOf(address(this)));
        col.transfer(depositor, col.balanceOf(address(this)));
    }
}

contract Exploit {
    Erc20 public weth;
    Erc20 public col;
    PoolManager public pool;
    UniswapImplementation public impl;
    Locker public locker;
    Peripheral public peripheral;

    constructor() {
        weth = new Erc20("WETH");
        col = new Erc20("COLL");
        pool = new PoolManager(weth, col);
        impl = new UniswapImplementation(pool, weth, col);
        locker = new Locker(impl, weth, col);
        impl.setLocker(address(locker));
        peripheral = new Peripheral(pool);
        weth.mint(address(this), 10 ether);
        col.mint(address(this), 10 ether);
    }

    function run() external {
        weth.approve(address(locker), 10 ether);
        col.approve(address(locker), 10 ether);
        locker.initializeCollection(10 ether, 10 ether);
        require(pool.liquidityOf(address(impl)) == 10 ether, "owner");
        (bool pulled,) = address(peripheral).call(abi.encodeWithSelector(peripheral.pull.selector));
        require(!pulled, "peripheral");
        require(weth.balanceOf(address(pool)) == 10 ether, "weth");
        require(col.balanceOf(address(pool)) == 10 ether, "col");
        require(weth.balanceOf(address(this)) == 0, "user weth");
        require(col.balanceOf(address(this)) == 0, "user col");
    }
}
