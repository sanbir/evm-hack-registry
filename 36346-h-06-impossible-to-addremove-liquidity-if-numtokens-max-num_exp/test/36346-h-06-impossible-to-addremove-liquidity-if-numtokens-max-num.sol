// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Lucidly add/remove liquidity (Pashov). amounts_ is a fixed array of
    length 32, so amounts_.length is always 32. A 2-token pool requires
    length == numTokens and therefore never pays an LP. A dynamic array
    of length 2 returns the 200 of liquidity.
*/

error Pool__InvalidParams();

contract Pool {
    uint256 public constant MAX_NUM_TOKENS = 32;
    uint256 public numTokens = 2;
    uint256 public liquidity = 200 ether;
    mapping(address => uint256) public lpOf;
    uint256 public lastOut;
    uint256 public lastLen;
    uint256 public lastExpected;
    bool public rejected;
    uint256 public stuckLp;
    uint256 public stuckReserves;

    function seed(address lp, uint256 amount) external {
        lpOf[lp] = amount;
    }

    function removeLiquidity(uint256[MAX_NUM_TOKENS] calldata amounts, address receiver) external returns (uint256 out) {
        uint256 given = amounts.length;
        lastLen = given;
        uint256 expected = numTokens;
        lastExpected = expected;
        if (given != expected) {
            rejected = true;
            lastOut = 0; // @> VULN: a uint256[32] always reports length 32, so a 2-token pool never pays
            stuckLp = lpOf[receiver];
            stuckReserves = liquidity;
            return 0;
        }
        out = lpOf[receiver];
        lpOf[receiver] = 0;
        liquidity -= out;
        lastOut = out;
    }
}

contract PoolFixed {
    uint256 public numTokens = 2;
    uint256 public liquidity = 200 ether;
    mapping(address => uint256) public lpOf;

    function seed(address lp, uint256 amount) external {
        lpOf[lp] = amount;
    }

    function removeLiquidity(uint256[] calldata amounts, address receiver) external returns (uint256 out) {
        require(amounts.length == numTokens, "len");
        out = lpOf[receiver];
        lpOf[receiver] = 0;
        liquidity -= out;
    }
}

contract StuckMarker {
    string public symbol = "LOCKED-LP";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant LP = 200 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Pool public pool;
    StuckMarker public marker;

    function run() external {
        pool = new Pool();
        marker = new StuckMarker();
        pool.seed(address(this), LP);
        uint256[32] memory amounts;
        amounts[0] = 100 ether;
        amounts[1] = 100 ether;
        uint256 out = pool.removeLiquidity(amounts, address(this));
        require(out == 0, "paid");
        require(pool.lpOf(address(this)) == LP, "lp remains");
        require(pool.liquidity() == LP, "reserves remain");
        marker.mint(SINK, LP);
        require(marker.balanceOf(SINK) == LP, "200 locked");
    }
}
