// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-40] BalancerStrategy.sol: _withdraw withdraws insufficient
    tokens (Code4rena 2023-07-tapioca, reporter carrotsmuggler, #27530).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: BalancerStrategy._withdraw converts the desired WETH amount
    into BPT by dividing by pricePerShare (getRate), then passes that BPT
    figure into _vaultWithdraw as if it were a minAmountsOut of WETH for a
    type-2 exact-tokens-out exit. Type-2 exits withdraw EXACTLY the token
    amounts in minAmountsOut — so the strategy only receives the BPT-scaled
    (much smaller) WETH amount, then require(amount <= balance) reverts.

    Blamed scaling + exit encoding preserved with @> VULN.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal Balancer BPT: getRate returns pricePerShare (e.g. 1.02e18).
contract MockPool is MockERC20 {
    uint256 public rate; // 1e18 = 1.0

    constructor(uint256 _rate) MockERC20("BPT", "BPT", 18) {
        rate = _rate;
    }

    function getRate() external view returns (uint256) {
        return rate;
    }
}

/// @notice Minimal Balancer Vault: type-2 exit pays exact minAmountsOut[0] WETH.
contract MockBalancerVault {
    MockERC20 public weth;
    MockPool public pool;

    constructor(MockERC20 _weth, MockPool _pool) {
        weth = _weth;
        pool = _pool;
    }

    /// @dev Type-2 userData = abi.encode(2, minAmountsOut, maxBptIn).
    ///      Pays EXACTLY minAmountsOut[0] WETH (as shown on Tenderly in report).
    function exitPool(bytes memory userData, address recipient) external {
        (uint256 kind, uint256[] memory minAmountsOut, uint256 maxBptIn) =
            abi.decode(userData, (uint256, uint256[], uint256));
        require(kind == 2, "kind");
        uint256 wethOut = minAmountsOut[0];
        // Burn up to maxBptIn from strategy (simplified 1:1 BPT burn for demo).
        uint256 bptBurn = maxBptIn < wethOut ? maxBptIn : wethOut;
        if (bptBurn > pool.balanceOf(msg.sender)) bptBurn = pool.balanceOf(msg.sender);
        pool.burn(msg.sender, bptBurn);
        weth.mint(recipient, wethOut);
    }
}

/// @notice Reduced BalancerStrategy.
contract BalancerStrategy {
    MockERC20 public wrappedNative;
    MockPool public pool;
    MockBalancerVault public vault;
    uint256 public queued; // idle WETH already on strategy

    constructor(MockERC20 _weth, MockPool _pool, MockBalancerVault _vault) {
        wrappedNative = _weth;
        pool = _pool;
        vault = _vault;
    }

    function seed(uint256 bptAmt, uint256 idleWeth) external {
        pool.mint(address(this), bptAmt);
        if (idleWeth > 0) {
            wrappedNative.mint(address(this), idleWeth);
            queued = idleWeth;
        }
    }

    /// @dev Verbatim reduction of the blamed _withdraw scaling + vault exit.
    function _withdraw(uint256 amount) internal {
        if (amount > queued) {
            uint256 pricePerShare = pool.getRate();
            uint256 decimals = pool.decimals();
            // @> VULN: scales WETH amount DOWN by pricePerShare, then treats
            // the result as exact minAmountsOut of WETH (type-2 exit).
            // FIX: pass (amount - queued) without scaling (or convert properly
            // to BPT for a type-1 exact-BPT-in exit).
            uint256 toWithdraw = (((amount - queued) * (10 ** decimals)) / pricePerShare);

            _vaultWithdraw(toWithdraw);
        }
        require(
            amount <= wrappedNative.balanceOf(address(this)),
            "BalancerStrategy: not enough"
        );
        // Real code then transfers `amount` to YieldBox — omitted.
        if (queued >= amount) queued -= amount;
        else queued = 0;
    }

    function _vaultWithdraw(uint256 amountOut) internal {
        uint256[] memory minAmountsOut = new uint256[](2);
        minAmountsOut[0] = amountOut; // treated as exact WETH out
        minAmountsOut[1] = 0;
        bytes memory userData = abi.encode(
            2,
            minAmountsOut,
            pool.balanceOf(address(this))
        );
        vault.exitPool(userData, address(this));
    }

    function withdraw(uint256 amount) external {
        _withdraw(amount);
    }
}

contract Exploit {
    MockERC20 public weth;
    MockPool public pool;
    MockBalancerVault public vault;
    BalancerStrategy public strategy;

    uint256 public constant RATE = 2e18; // pricePerShare = 2.0 → halves amount
    uint256 public constant WANT = 1000 ether;
    bool public withdrawReverted;

    constructor() {
        weth = new MockERC20("WETH", "WETH", 18);
        pool = new MockPool(RATE);
        vault = new MockBalancerVault(weth, pool);
        strategy = new BalancerStrategy(weth, pool, vault);
        // Strategy holds ample BPT, no idle queued WETH.
        strategy.seed(10_000 ether, 0);
    }

    function run() external {
        // User requests WANT WETH. Scaling by rate=2 yields only WANT/2 WETH
        // from the vault → require fails.
        (bool ok, ) = address(strategy).call(
            abi.encodeWithSelector(BalancerStrategy.withdraw.selector, WANT)
        );
        withdrawReverted = !ok;
        require(withdrawReverted, "harm: withdraw must revert (insufficient)");
        // Strategy still holds its BPT — funds effectively stuck for full withdraw.
        require(pool.balanceOf(address(strategy)) > 0, "still has BPT");
        require(weth.balanceOf(address(strategy)) < WANT, "never reached WANT");
    }
}
