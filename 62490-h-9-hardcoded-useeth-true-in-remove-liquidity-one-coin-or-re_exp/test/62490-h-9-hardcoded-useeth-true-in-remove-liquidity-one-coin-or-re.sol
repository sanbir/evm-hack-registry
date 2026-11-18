// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Notional Exponent — hardcoded useEth on Curve V2 exit (Sherlock H-9, 62490)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _enterPool sets use_eth from msg.value (false for a WETH vault),
    but _exitPool hardcodes use_eth = true. The pool sends native ETH. The vault
    wraps only when TOKEN_1 or TOKEN_2 is ETH_ADDRESS, so the WETH delta is 0
    and the 10 ETH stays stuck. Vulnerable lines preserved verbatim (@> VULN). */

interface ICurve2TokenPoolV2 {
    function add_liquidity(uint256[] calldata amounts, uint256 minMint, bool useEth) external payable returns (uint256);
    function remove_liquidity_one_coin(uint256 lp, uint256 i, uint256 minAmt, bool useEth, address receiver)
        external
        returns (uint256);
    function remove_liquidity(uint256 lp, uint256[] calldata minAmounts, bool useEth, address receiver) external;
}

contract WETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "weth");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "withdraw");
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address from, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - a;
        _move(from, to, a);
        return true;
    }

    function _move(address from, address to, uint256 a) internal {
        require(balanceOf[from] >= a, "bal");
        balanceOf[from] -= a;
        balanceOf[to] += a;
    }

    receive() external payable {}
}

contract OtherToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

/// Curve V2 pool, coin 0 = WETH, ETH_INDEX = 0. use_eth unwraps that coin.
contract CurveV2Pool is ICurve2TokenPoolV2 {
    WETH public weth;
    mapping(address => uint256) public lpOf;
    uint256 public totalLp;

    constructor(WETH _weth) { weth = _weth; }

    function add_liquidity(uint256[] calldata amounts, uint256, bool useEth) external payable returns (uint256 minted) {
        if (useEth) {
            require(msg.value == amounts[0], "incorrect eth amount");
        } else if (amounts[0] > 0) {
            require(weth.transferFrom(msg.sender, address(this), amounts[0]), "pull");
            weth.withdraw(amounts[0]); // pool holds native ETH, matching the Vyper withdraw
        }
        minted = amounts[0];
        lpOf[msg.sender] += minted;
        totalLp += minted;
    }

    function remove_liquidity_one_coin(uint256 lp, uint256 i, uint256, bool useEth, address receiver)
        external
        returns (uint256 out)
    {
        require(lpOf[msg.sender] >= lp, "lp");
        lpOf[msg.sender] -= lp;
        totalLp -= lp;
        out = lp;
        if (useEth && i == 0) {
            (bool ok,) = receiver.call{value: out}(""); // STORY5 native ETH, not WETH
            require(ok, "eth send");
        } else {
            weth.deposit{value: out}();
            require(weth.transfer(receiver, out), "weth out");
        }
    }

    function remove_liquidity(uint256, uint256[] calldata, bool, address) external pure {}

    receive() external payable {}
}

contract CurveConvex2Token {
    address public constant ETH_ADDRESS = address(0);
    WETH public immutable WETH_TOKEN;
    address public immutable ASSET;
    address public immutable TOKEN_1;
    address public immutable TOKEN_2;
    ICurve2TokenPoolV2 public immutable CURVE_POOL;
    uint256 internal constant _PRIMARY_INDEX = 0;
    uint256 internal constant _NUM_TOKENS = 2;
    mapping(address => uint256) public shares;
    uint256 public lastAssetsWithdrawn;
    uint256 public stuckEth;

    constructor(WETH weth, OtherToken token2, ICurve2TokenPoolV2 pool) {
        WETH_TOKEN = weth;
        ASSET = address(weth);
        TOKEN_1 = address(weth); // coin 0 is WETH, not native ETH
        TOKEN_2 = address(token2);
        CURVE_POOL = pool;
    }

    function deposit(uint256 assets) external {
        require(WETH_TOKEN.transferFrom(msg.sender, address(this), assets), "pull weth");
        require(WETH_TOKEN.approve(address(CURVE_POOL), assets), "approve");
        uint256[] memory amounts = new uint256[](_NUM_TOKENS);
        amounts[0] = assets;
        uint256 minted = _enterPool(amounts, 0, 0);
        shares[msg.sender] = minted;
    }

    function _enterPool(uint256[] memory amounts, uint256 minPoolClaim, uint256 msgValue) internal returns (uint256) {
        return CURVE_POOL.add_liquidity{value: msgValue}(amounts, minPoolClaim, 0 < msgValue); // STORY2 use_eth = (0 < msgValue)
    }

    function redeem() external returns (uint256 assetsWithdrawn) {
        uint256 poolClaim = shares[msg.sender];
        uint256[] memory minAmounts = new uint256[](_NUM_TOKENS);
        assetsWithdrawn = _burnShares(poolClaim, minAmounts, true);
    }

    function unstakeAndExitPool(uint256 poolClaim, uint256[] memory _minAmounts, bool isSingleSided)
        public
        returns (uint256[] memory exitBalances)
    {
        exitBalances = _exitPool(poolClaim, _minAmounts, isSingleSided);

        if (ASSET == address(WETH_TOKEN)) {
            if (TOKEN_1 == ETH_ADDRESS) {
                WETH_TOKEN.deposit{value: exitBalances[0]}();
            } else if (TOKEN_2 == ETH_ADDRESS) {
                WETH_TOKEN.deposit{value: exitBalances[1]}();
            }
        }
    }

    function _exitPool(uint256 poolClaim, uint256[] memory _minAmounts, bool isSingleSided)
        internal
        returns (uint256[] memory exitBalances)
    {
        if (isSingleSided) {
            exitBalances = new uint256[](_NUM_TOKENS);
            // Last two parameters are useEth = true and receiver = this contract
            exitBalances[_PRIMARY_INDEX] = CURVE_POOL.remove_liquidity_one_coin(poolClaim, _PRIMARY_INDEX, _minAmounts[_PRIMARY_INDEX], true, address(this)); // @> VULN: useEth hardcoded true
            // FIX: pass (TOKEN_1 == ETH_ADDRESS) instead of true
        } else {
            exitBalances = new uint256[](_NUM_TOKENS);
            ICurve2TokenPoolV2(CURVE_POOL).remove_liquidity(
                poolClaim, _minAmounts, true, address(this)
            );
        }
    }

    function _burnShares(uint256 sharesToBurn, uint256[] memory minAmounts, bool isSingleSided)
        internal
        returns (uint256 assetsWithdrawn)
    {
        if (sharesToBurn == 0) return 0;
        uint256 initialAssetBalance = WETH_TOKEN.balanceOf(address(this)); // STORY3
        unstakeAndExitPool(sharesToBurn, minAmounts, isSingleSided);
        shares[msg.sender] = 0;
        uint256 finalAssetBalance = WETH_TOKEN.balanceOf(address(this));
        assetsWithdrawn = finalAssetBalance - initialAssetBalance; // STORY6 zero WETH delta
        lastAssetsWithdrawn = assetsWithdrawn;
        stuckEth = address(this).balance;
    }

    receive() external payable {}
}

/// Control: same exit, but useEth is false when neither coin is native ETH.
contract CurveConvex2TokenFixed {
    WETH public immutable WETH_TOKEN;
    ICurve2TokenPoolV2 public immutable CURVE_POOL;
    mapping(address => uint256) public shares;

    constructor(WETH weth, ICurve2TokenPoolV2 pool) {
        WETH_TOKEN = weth;
        CURVE_POOL = pool;
    }

    function deposit(uint256 assets) external {
        require(WETH_TOKEN.transferFrom(msg.sender, address(this), assets), "pull");
        require(WETH_TOKEN.approve(address(CURVE_POOL), assets), "ap");
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = assets;
        uint256 minted = CURVE_POOL.add_liquidity{value: 0}(amounts, 0, false);
        shares[msg.sender] = minted;
    }

    function redeem() external returns (uint256 assetsWithdrawn) {
        uint256 beforeBal = WETH_TOKEN.balanceOf(address(this));
        uint256 lp = shares[msg.sender];
        shares[msg.sender] = 0;
        CURVE_POOL.remove_liquidity_one_coin(lp, 0, 0, false, address(this));
        assetsWithdrawn = WETH_TOKEN.balanceOf(address(this)) - beforeBal;
        require(WETH_TOKEN.transfer(msg.sender, assetsWithdrawn), "pay");
    }
}

contract Exploit {
    WETH public weth; // nonce 1
    OtherToken public token2; // nonce 2
    CurveV2Pool public pool; // nonce 3
    CurveConvex2Token public vault; // nonce 4
    uint256 public constant AMOUNT = 10 ether;

    constructor() {
        weth = new WETH();
        token2 = new OtherToken();
        pool = new CurveV2Pool(weth);
        vault = new CurveConvex2Token(weth, token2, pool);
    }

    function run() external payable {
        require(msg.value == AMOUNT, "value");
        weth.deposit{value: AMOUNT}();
        require(weth.approve(address(vault), AMOUNT), "ap");
        vault.deposit(AMOUNT); // STORY1
        uint256 got = vault.redeem();
        require(got == 0, "user was paid WETH");
        require(vault.lastAssetsWithdrawn() == 0, "delta");
        require(address(vault).balance == AMOUNT, "eth not stuck");
        require(weth.balanceOf(address(this)) == 0, "user received weth");
        require(weth.balanceOf(address(vault)) == 0, "vault holds weth");
    }
}
