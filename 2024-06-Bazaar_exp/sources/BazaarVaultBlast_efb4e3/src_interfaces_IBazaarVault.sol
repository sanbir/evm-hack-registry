pragma solidity >=0.7.0 <0.9.0;
pragma experimental ABIEncoderV2;

interface IBazaarVault {
    // @notice reverts if `(from|to)InternalBalance` is set
    struct FundManagement {
        address sender;
        bool fromInternalBalance; // UNSUPPORTED
        address payable recipient;
        bool toInternalBalance; // UNSUPPORTED
    }

    // UNSUPPORTED
    function getProtocolFeesCollector() external view returns (address);

    /// Registration ////

    enum PoolSpecialization {
        GENERAL,
        MINIMAL_SWAP_INFO,
        TWO_TOKEN
    }

    function registerPool(PoolSpecialization specialization) external returns (bytes32);

    function registerTokens(bytes32 poolId, address[] memory tokens, address[] memory assetManagers) external;

    // @notice `lastChangeBlock` always returns 0
    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (address[] memory tokens, uint256[] memory balances, uint256);

    //// SWAPS ////

    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    event Swap(
        bytes32 indexed poolId, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address tokenIn;
        address tokenOut;
        uint256 amount;
        bytes userData;
    }

    function swap(SingleSwap memory singleSwap, FundManagement memory funds, uint256 limit, uint256 deadline)
        external
        payable
        returns (uint256);

    function querySwap(SingleSwap memory singleSwap) external view returns (uint256);

    //// Joins ////

    struct JoinPoolRequest {
        address[] tokens;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance; // UNSUPPORTED
    }

    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable;

    //// Exits ////

    struct ExitPoolRequest {
        address[] tokens;
        uint256[] minAmountsOut;
        bytes userData;
        bool toInternalBalance; // UNSUPPORTED
    }

    function exitPool(bytes32 poolId, address sender, address payable recipient, ExitPoolRequest memory request)
        external;
}
