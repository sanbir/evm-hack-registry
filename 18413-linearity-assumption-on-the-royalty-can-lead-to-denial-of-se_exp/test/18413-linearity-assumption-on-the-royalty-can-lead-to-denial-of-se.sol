// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Sudoswap VeryFastRouter — linear royalty quote (Cyfrin, June 2023)
    SYNTHETIC, cheatcode-free reduction.
    Two NFTs gross 1 ETH. The router subtracts a flat 10 percent and sets min output
    to 0.9 ETH. The collection's royalty for a 2-NFT sale is 0.8 ETH, so the pair
    can only pay 0.2 ETH and the swap reverts. The 2 NFTs stay in the pair.
    Quoting the actual curve pays 0.2 ETH and releases the NFTs. */

contract Erc20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LSSVMPair {
    Erc20 public nft;
    Erc20 public weth;

    constructor(Erc20 nft_, Erc20 weth_) {
        nft = nft_;
        weth = weth_;
    }

    function actualOutput(uint256 numItems) public pure returns (uint256 outputAmount) {
        uint256 gross = numItems * 0.5 ether;
        uint256 royalty = numItems == 2 ? 0.8 ether : gross / 10;
        outputAmount = gross - royalty;
    }

    function swapNFTsForToken(uint256 numItems, uint256 minOutput, address recipient) external returns (uint256 outputAmount) {
        require(nft.balanceOf(address(this)) >= numItems, "nft");
        outputAmount = actualOutput(numItems);
        require(outputAmount >= minOutput, "slippage");
        nft.transfer(msg.sender, numItems);
        weth.transfer(recipient, outputAmount);
    }
}

contract VeryFastRouter {
    uint256 public constant BASE = 1e18;
    uint256 public constant ROYALTY_AMOUNT = 0.1 ether;

    LSSVMPair public pair;

    constructor(LSSVMPair pair_) {
        pair = pair_;
    }

    function quoteLinear(uint256 numItems) public pure returns (uint256 currentOutput) {
        currentOutput = numItems * 0.5 ether;
        // @> VULN: currentOutput is reduced by a constant royalty fraction, so a non-linear royalty makes the quote unpayable
        currentOutput -= currentOutput * ROYALTY_AMOUNT / BASE;
    }

    function sell(address seller, uint256 numItems) external returns (uint256 paid) {
        uint256 priceToFillAt = quoteLinear(numItems);
        paid = pair.swapNFTsForToken(numItems, priceToFillAt, seller);
    }

    function trySell(address seller, uint256 numItems) external returns (bool sold) {
        try this.sell(seller, numItems) returns (uint256) {
            sold = true;
        } catch {
            sold = false;
        }
    }

    function sellActual(address seller, uint256 numItems) external returns (uint256 paid) {
        uint256 priceToFillAt = pair.actualOutput(numItems);
        paid = pair.swapNFTsForToken(numItems, priceToFillAt, seller);
    }
}

contract Exploit {
    Erc20 public nft; // nonce 1
    Erc20 public weth; // nonce 2
    LSSVMPair public pair; // nonce 3
    VeryFastRouter public router; // nonce 4

    uint256 public linearQuote;
    uint256 public actualQuote;
    bool public sold;
    uint256 public nftsStuck;
    uint256 public ethPaid;

    constructor() {
        nft = new Erc20("Collection", "NFT", 0);
        weth = new Erc20("Ether", "WETH", 18);
        pair = new LSSVMPair(nft, weth);
        router = new VeryFastRouter(pair);
        nft.mint(address(this), 2);
        weth.mint(address(pair), 1 ether);
    }

    function run() external {
        nft.transfer(address(pair), 2);
        linearQuote = router.quoteLinear(2);
        actualQuote = pair.actualOutput(2);
        sold = router.trySell(address(this), 2);
        nftsStuck = nft.balanceOf(address(pair));
        ethPaid = weth.balanceOf(address(this));
        require(!sold, "sell succeeded");
        require(linearQuote == 0.9 ether, "linear quote");
        require(actualQuote == 0.2 ether, "actual output");
        require(nftsStuck == 2, "nfts not stuck");
        require(ethPaid == 0, "eth was paid");
        require(weth.balanceOf(address(pair)) == 1 ether, "pair eth moved");
    }

    function runControl() external returns (uint256 paid) {
        nft.transfer(address(pair), 2);
        paid = router.sellActual(address(this), 2);
    }
}
