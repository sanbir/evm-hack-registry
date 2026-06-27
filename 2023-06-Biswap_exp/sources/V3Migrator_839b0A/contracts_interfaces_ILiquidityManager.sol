// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

/// @title Interface for LiquidityManager
interface ILiquidityManager is IERC721Enumerable {

    /// @notice Emitted when miner successfully add liquidity on an existing liquidity-nft
    /// @param nftId id of minted liquidity nft
    /// @param pool address of swap pool
    /// @param liquidityDelta the amount of liquidity added
    /// @param amountX amount of tokenX deposit
    /// @param amountY amount of tokenY deposit
    event AddLiquidity(
        uint256 indexed nftId,
        address pool,
        uint128 liquidityDelta,
        uint256 amountX,
        uint256 amountY
    );

    /// @notice Emitted when miner successfully add decrease liquidity on an existing liquidity-nft
    /// @param nftId id of minted liquidity nft
    /// @param pool address of swap pool
    /// @param liquidityDelta the amount of liquidity decreased
    /// @param amountX amount of tokenX withdrawn
    /// @param amountY amount of tokenY withdrawn
    event DecLiquidity(
        uint256 indexed nftId,
        address pool,
        uint128 liquidityDelta,
        uint256 amountX,
        uint256 amountY
    );

    /// @notice Emitted when set new bonus pool manager contract
    /// @param _bonusPoolManager new bonus pool manager address
    event SetBonusPoolManager(address _bonusPoolManager);

    /// @notice Emitted when get error on hook call
    /// @param receiver hook receiver address
    /// @param returnData retern revert data
    event HookError(address receiver,  bytes returnData);

    /// @nitice parameters when calling mint, grouped together to avoid stake too deep
    /// @param miner miner address
    /// @param tokenX address of tokenX
    /// @param tokenY address of tokenY
    /// @param fee current fee of pool
    /// @param pl left point of added liquidity
    /// @param pr right point of added liquidity
    /// @param xLim amount limit of tokenX miner willing to deposit
    /// @param yLim amount limit tokenY miner willing to deposit
    /// @param amountXMin minimum amount of tokenX miner willing to deposit
    /// @param amountYMin minimum amount of tokenY miner willing to deposit
    /// @param deadline deadline of transaction
    struct MintParam {
        address miner;
        address tokenX;
        address tokenY;
        uint16 fee;
        int24 pl;
        int24 pr;
        uint128 xLim;
        uint128 yLim;
        uint128 amountXMin;
        uint128 amountYMin;
        uint256 deadline;
    }

    /// @notice parameters when calling addLiquidity, grouped together
    /// @dev to avoid stake too deep
    /// @param lid id of nft
    /// @param xLim amount limit of tokenX user willing to deposit
    /// @param yLim amount limit of tokenY user willing to deposit
    /// @param amountXMin min amount of tokenX user willing to deposit
    /// @param amountYMin min amount of tokenY user willing to deposit
    /// @param deadline deadline for completing transaction
    struct AddLiquidityParam {
        uint256 lid;
        uint128 xLim;
        uint128 yLim;
        uint128 amountXMin;
        uint128 amountYMin;
        uint256 deadline;
    }

    /// @notice pool data
    /// @param tokenX address of token X
    /// @param fee fee of pool
    /// @param tokenY address of token X
    /// @param pool pool address
    struct PoolMeta {
        address tokenX;
        uint16 fee;
        address tokenY;
        address pool;
    }

    /// @notice information of liquidity provided by miner
    /// @param leftPt left point of liquidity-token, the range is [leftPt, rightPt)
    /// @param rightPt right point of liquidity-token, the range is [leftPt, rightPt)
    /// @param feeVote Vote for fee on liquidity position
    /// @param liquidity amount of liquidity on each point in [leftPt, rightPt)
    /// @param lastFeeScaleX_128 a 128-fixpoint number, as integral of { fee(pt, t)/L(pt, t) }
    /// @param lastFeeScaleY_128 a 128-fixpoint number, as integral of { fee(pt, t)/L(pt, t) }
    /// @dev here fee(pt, t) denotes fee generated on point pt at time t
    /// L(pt, t) denotes liquidity on point pt at time t
    /// pt varies in [leftPt, rightPt)
    /// t moves from pool created until miner last modify this liquidity-token (mint/addLiquidity/decreaseLiquidity/create)
    /// @param lastFPScale_128 a 128-fixpoint number last FPScale of 1 liquidity
    /// @param remainTokenX remained tokenX miner can collect, including fee and withdrawn token
    /// @param remainTokenY remained tokenY miner can collect, including fee and withdrawn token
    /// @param fpOwed Accrued fp for liquidity position
    /// @param poolId id of pool in which this liquidity is added
    struct Liquidity {
        int24 leftPt;
        int24 rightPt;
        uint16 feeVote;
        uint128 liquidity;
        uint256 lastFeeScaleX_128;
        uint256 lastFeeScaleY_128;
        uint256 lastFPScale_128;
        uint256 remainTokenX;
        uint256 remainTokenY;
        uint256 fpOwed;
        uint128 poolId;
    }

    /// @notice callback data passed through BiswapPoolV3#mint to the callback
    /// @param tokenX tokenX of swap
    /// @param tokenY tokenY of swap
    /// @param fee fee amount of swap
    /// @param payer address to pay tokenX and tokenY to BiswapPoolV3
    struct MintCallbackData {
        address tokenX;
        address tokenY;
        uint16 fee;
        address payer;
    }


    /// @notice Add a new liquidity and generate a nft.
    /// @param mintParam params, see MintParam for more
    /// @return lid id of nft
    /// @return liquidity amount of liquidity added
    /// @return amountX amount of tokenX deposited
    /// @return amountY amount of tokenY depsoited
    function mint(MintParam calldata mintParam) external payable returns(
        uint256 lid,
        uint128 liquidity,
        uint256 amountX,
        uint256 amountY
    );

    /// @notice Add a new liquidity and generate a nft.
    /// @param mintParam params, see MintParam for more
    /// @param feeVote vote for fee at liquidity position
    /// @return lid id of nft
    /// @return liquidity amount of liquidity added
    /// @return amountX amount of tokenX deposited
    /// @return amountY amount of tokenY deposited
    function mintWithFeeVote(MintParam calldata mintParam, uint16 feeVote) external payable returns(
        uint256 lid,
        uint128 liquidity,
        uint256 amountX,
        uint256 amountY
    );

    /// @notice Burn a generated nft.
    /// @param lid nft (liquidity) id
    /// @return success successfully burn or not
    function burn(uint256 lid) external returns (bool success);

    /// @notice Add liquidity to a existing nft.
    /// @param addLiquidityParam see AddLiquidityParam for more
    /// @return liquidityDelta amount of added liquidity
    /// @return amountX amount of tokenX deposited
    /// @return amountY amonut of tokenY deposited
    function addLiquidity(
        AddLiquidityParam calldata addLiquidityParam
    ) external payable returns (
        uint128 liquidityDelta,
        uint256 amountX,
        uint256 amountY
    );

    /// @notice Decrease liquidity from a nft.
    /// @param lid id of nft
    /// @param liquidDelta amount of liqudity to decrease
    /// @param amountXMin min amount of tokenX user want to withdraw
    /// @param amountYMin min amount of tokenY user want to withdraw
    /// @param deadline deadline timestamp of transaction
    /// @return amountX amount of tokenX refund to user
    /// @return amountY amount of tokenY refund to user
    function decLiquidity(
        uint256 lid,
        uint128 liquidDelta,
        uint256 amountXMin,
        uint256 amountYMin,
        uint256 deadline
    ) external returns (
        uint256 amountX,
        uint256 amountY
    );

    /// @notice Change vote for fee on exist NFT
    /// @param lid NFT Id
    /// @param newFeeVote new vote for fee on NFT position
    function changeFeeVote(uint256 lid, uint16 newFeeVote) external;

    /// @notice get liquidity info from NFT Id
    /// @param lid NFT id
    /// @return leftPt left point of liquidity-token, the range is [leftPt, rightPt)
    /// @return rightPt right point of liquidity-token, the range is [leftPt, rightPt)
    /// @return feeVote Vote for fee on liquidity position
    /// @return liquidity amount of liquidity on each point in [leftPt, rightPt)
    /// @return lastFeeScaleX_128 a 128-fixpoint number, as integral of { fee(pt, t)/L(pt, t) }
    /// @return lastFeeScaleY_128 a 128-fixpoint number, as integral of { fee(pt, t)/L(pt, t) }
    /// @dev here fee(pt, t) denotes fee generated on point pt at time t
    /// L(pt, t) denotes liquidity on point pt at time t
    /// pt varies in [leftPt, rightPt)
    /// t moves from pool created until miner last modify this liquidity-token (mint/addLiquidity/decreaseLiquidity/create)
    /// @return lastFPScale_128 a 128-fixpoint number last FPScale of 1 liquidity
    /// @return remainTokenX remained tokenX miner can collect, including fee and withdrawn token
    /// @return remainTokenY remained tokenY miner can collect, including fee and withdrawn token
    /// @return fpOwed Accrued fp for liquidity position
    /// @return poolId id of pool in which this liquidity is added
    function liquidities(uint256 lid) external view returns(
        int24 leftPt,
        int24 rightPt,
        uint16 feeVote,
        uint128 liquidity,
        uint256 lastFeeScaleX_128,
        uint256 lastFeeScaleY_128,
        uint256 lastFPScale_128,
        uint256 remainTokenX,
        uint256 remainTokenY,
        uint256 fpOwed,
        uint128 poolId
    );

    /// @notice info of pool from poolId
    /// @param poolId pool Id
    /// @return tokenX address of token X
    /// @return fee fee of pool
    /// @return tokenY address of token X
    /// @return pool pool address
    function poolMetas(uint128 poolId) external view returns(
        address tokenX,
        uint16 fee,
        address tokenY,
        address pool
    );

    /// @notice Collect fee gained of token withdrawn from nft.
    /// @param recipient address to receive token
    /// @param lid id of nft
    /// @param amountXLim amount limit of tokenX to collect
    /// @param amountYLim amount limit of tokenY to collect
    /// @return amountX amount of tokenX actually collect
    /// @return amountY amount of tokenY actually collect
    function collect(
        address recipient,
        uint256 lid,
        uint128 amountXLim,
        uint128 amountYLim
    ) external payable returns (
        uint256 amountX,
        uint256 amountY
    );

    /// @notice update farm point from pool
    /// @param lid NFT Id
    function updateFpOwed(uint256 lid) external;

    /// @notice Set new bonus pool manager contract
    /// @dev only owner call
    /// @param _bonusPoolManager new bonus pool manager address
    function setBonusPoolManager(address _bonusPoolManager) external;
}
