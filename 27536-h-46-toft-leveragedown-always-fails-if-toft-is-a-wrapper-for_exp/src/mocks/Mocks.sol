// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "tapioca-periph/contracts/interfaces/ISwapper.sol";
import "tapioca-periph/contracts/interfaces/IUSDO.sol";
import "tapioca-periph/contracts/interfaces/ICommonData.sol";

/// @dev Minimal opaque ERC20 used as the *underlying* for the non-native control TOFT.
///      The vulnerable TapiocaOFT treats an ERC20 underlying as a black box, so a plain
///      real ERC20 is an accurate boundary here.
contract TestERC20 is ERC20 {
    constructor() ERC20("Underlying", "UND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Opaque LayerZero endpoint boundary. On the destination chain the endpoint is the
///      only address allowed to invoke `lzReceive`. We drive an inbound leverage-down
///      packet exactly as the real relayer would.
interface ITOFTReceive {
    function lzReceive(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) external;
}

contract MockLZEndpoint {
    /// @notice Deliver an inbound LZ message to the TOFT (as the endpoint would).
    function deliver(
        address toft,
        uint16 srcChainId,
        bytes calldata srcAddress,
        uint64 nonce,
        bytes calldata payload
    ) external {
        ITOFTReceive(toft).lzReceive(srcChainId, srcAddress, nonce, payload);
    }

    // Defensive no-ops in case any code path touches the endpoint interface.
    function getChainId() external pure returns (uint16) {
        return 1;
    }

    receive() external payable {}
}

/// @dev Opaque DEX aggregator boundary (ISwapper). Records whether it was reached so the
///      test can prove *where* the native path dies (before ever reaching the swapper).
contract MockSwapper {
    bool public swapReached;

    // NOTE: ISwapper.buildSwapData is `view`, so the TOFT invokes it via STATICCALL.
    // It must therefore not write state; the "did we get past the approve" signal is
    // recorded in `swap` below (a normal CALL) instead.
    function buildSwapData(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 shareIn,
        bool withdrawFromYb,
        bool depositToYb
    ) external pure returns (ISwapper.SwapData memory swapData) {
        swapData.tokensData = ISwapper.SwapTokensData(tokenIn, 0, tokenOut, 0);
        swapData.amountData = ISwapper.SwapAmountData(amountIn, shareIn, 0, 0);
        swapData.yieldBoxData = ISwapper.YieldBoxData(withdrawFromYb, depositToYb);
    }

    function swap(
        ISwapper.SwapData calldata swapData,
        uint256 amountOutMin,
        address to,
        bytes calldata dexOptions
    ) external returns (uint256 amountOut, uint256 shareOut) {
        swapReached = true;
        amountOut = swapData.amountData.amountIn; // 1:1 opaque swap
        shareOut = 0;
    }
}

/// @dev Opaque Magnetar helper boundary.
contract MockMagnetar {
    function getBorrowPartForAmount(
        address,
        uint256 amount
    ) external pure returns (uint256) {
        return amount;
    }
}

/// @dev Opaque USDO (swap output token) boundary. The real repay leg is a cross-chain
///      LZ send handled off-domain; here it is a no-op sink so the ERC20 control path can
///      complete end-to-end.
contract MockUSDO {
    bool public repayReached;

    function sendAndLendOrRepay(
        address,
        address,
        uint16,
        address,
        IUSDOBase.ILendOrRepayParams calldata,
        ICommonData.IApproval[] calldata,
        ICommonData.IWithdrawParams calldata,
        bytes calldata
    ) external payable {
        repayReached = true;
    }

    receive() external payable {}
}
