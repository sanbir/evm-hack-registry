// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  NiftyApes SellerFinancing — _validateSaleOrder does not require a single
    WETH offer (Quantstamp / Michael Boyle, finding #60495).

    SYNTHETIC, cheatcode-free. fulfillOrder pulls every offer item, then
    forwards only the WETH leg. The extra token stays in the contract with
    no withdraw. Control rejects offer.length != 1 before any pull. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SellerFinancing {
    struct OfferItem {
        address token;
        uint256 amount;
    }

    Token public weth;
    address public constant BUYER = address(0xBEEF);

    constructor(Token _weth) {
        weth = _weth;
    }

    function _validateSaleOrder(OfferItem[] memory offer, uint256 wethOut) internal view {
        require(offer.length >= 1, "offer");
        require(offer[0].token == address(weth), "weth");
        require(offer[0].amount == wethOut && wethOut > 0, "weth amount");
    }

    function fulfillOrder(OfferItem[] memory offer, uint256 wethOut) external {
        _validateSaleOrder(offer, wethOut);
        for (uint256 i; i < offer.length; i++) {
            // @> VULN: every offer item is pulled; only WETH is forwarded
            Token(offer[i].token).transferFrom(msg.sender, address(this), offer[i].amount);
        }
        weth.transfer(BUYER, wethOut);
    }
}

contract Exploit {
    uint256 public constant N = 500 ether;
    uint256 public constant WETH_LEG = 1 ether;

    Token public weth;
    Token public extra;
    SellerFinancing public financing;
    uint256 public stuck;
    uint256 public buyerWeth;

    constructor() {
        weth = new Token("Wrapped Ether", "WETH", 18);
        extra = new Token("Side Token", "SIDE", 18);
        financing = new SellerFinancing(weth);
        weth.mint(address(this), WETH_LEG);
        extra.mint(address(this), N);
    }

    function run() external {
        weth.approve(address(financing), WETH_LEG);
        extra.approve(address(financing), N);
        SellerFinancing.OfferItem[] memory offer = new SellerFinancing.OfferItem[](2);
        offer[0] = SellerFinancing.OfferItem(address(weth), WETH_LEG);
        offer[1] = SellerFinancing.OfferItem(address(extra), N);
        financing.fulfillOrder(offer, WETH_LEG);
        stuck = extra.balanceOf(address(financing));
        buyerWeth = weth.balanceOf(address(0xBEEF));
        require(stuck == N, "extra token was not locked");
        require(extra.balanceOf(address(this)) == 0, "seller kept the extra token");
        require(buyerWeth == WETH_LEG, "buyer did not receive WETH");
        require(weth.balanceOf(address(financing)) == 0, "WETH was not forwarded");
    }
}

/// @dev Control: reject an offer that is not exactly one WETH item.
contract SellerFinancingFixed {
    struct OfferItem {
        address token;
        uint256 amount;
    }

    Token public weth;

    constructor(Token _weth) {
        weth = _weth;
    }

    function fulfillOrder(OfferItem[] memory offer, uint256 wethOut) external {
        require(offer.length == 1, "one offer");
        require(offer[0].token == address(weth) && offer[0].amount == wethOut, "weth");
        weth.transferFrom(msg.sender, address(this), wethOut);
        weth.transfer(address(0xBEEF), wethOut);
    }
}
