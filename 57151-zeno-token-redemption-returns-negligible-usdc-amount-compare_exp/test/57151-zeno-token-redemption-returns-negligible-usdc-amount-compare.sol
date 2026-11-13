// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC ZENO.redeem (CodeHawks 2025-02, finding 57151)
    A ZENO bond is a whole-token count. USDC has 6 decimals. redeem burns `amount`
    bonds and safeTransfer's that same integer of USDC base units.
    100 bonds bought for 9,999.8959 USDC redeem for 100 base units (0.0001 USDC)
    instead of amount * 10**6 (100 USDC). The face reserve stays in the contract.

    CREATE order inside Exploit:
      nonce 1 Usdc, 2 Zeno, 3 Auction
*/

contract Usdc {
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
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

    function safeTransfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Zeno {
    Usdc public USDC;
    uint256 public maturity;
    address public minter;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    error BondNotRedeemable();
    error InsufficientBalance();

    constructor(Usdc _usdc, uint256 _maturity) {
        USDC = _usdc;
        maturity = _maturity;
    }

    function setMinter(address _minter) external {
        require(minter == address(0), "set");
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function redeem(uint256 amount) external {
        if (block.timestamp < maturity) revert BondNotRedeemable();
        _burn(msg.sender, amount);
        uint256 usdcBalance = USDC.balanceOf(address(this));
        if (usdcBalance < amount) revert InsufficientBalance();
        // @> VULN: pays `amount` USDC base units instead of amount * 10**6, so 100 ZENO returns 0.0001 USDC
        USDC.safeTransfer(msg.sender, amount);
    }
}

contract ZenoFixed {
    Usdc public USDC;
    uint256 public maturity;
    address public minter;
    mapping(address => uint256) public balanceOf;

    constructor(Usdc _usdc, uint256 _maturity) {
        USDC = _usdc;
        maturity = _maturity;
    }

    function setMinter(address _minter) external {
        require(minter == address(0), "set");
        minter = _minter;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function redeem(uint256 amount) external {
        require(block.timestamp >= maturity, "time");
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        uint256 usdcAmount = amount * (10 ** 6);
        require(USDC.balanceOf(address(this)) >= usdcAmount, "cash");
        USDC.safeTransfer(msg.sender, usdcAmount);
    }
}

contract Auction {
    Usdc public usdc;
    Zeno public zeno;
    address public business;
    uint256 public constant PRICE = 99_998_959;

    constructor(Usdc _usdc, Zeno _zeno, address _business) {
        usdc = _usdc;
        zeno = _zeno;
        business = _business;
    }

    function buy(uint256 zenoAmount) external {
        uint256 cost = zenoAmount * PRICE;
        usdc.transferFrom(msg.sender, business, cost);
        zeno.mint(msg.sender, zenoAmount);
    }
}

contract AuctionFixed {
    Usdc public usdc;
    ZenoFixed public zeno;
    address public business;
    uint256 public constant PRICE = 99_998_959;

    constructor(Usdc _usdc, ZenoFixed _zeno, address _business) {
        usdc = _usdc;
        zeno = _zeno;
        business = _business;
    }

    function buy(uint256 zenoAmount) external {
        uint256 cost = zenoAmount * PRICE;
        usdc.transferFrom(msg.sender, business, cost);
        zeno.mint(msg.sender, zenoAmount);
    }
}

contract Exploit {
    Usdc public usdc;
    Zeno public zeno;
    Auction public auction;
    address public constant BUSINESS = address(0xBEEF);
    uint256 public returned;
    uint256 public retained;

    constructor() {
        usdc = new Usdc();
        zeno = new Zeno(usdc, 1);
        auction = new Auction(usdc, zeno, BUSINESS);
        zeno.setMinter(address(auction));
        usdc.mint(address(this), 10_000 * 10 ** 6);
    }

    function run() external {
        usdc.approve(address(auction), type(uint256).max);
        auction.buy(100);
        require(zeno.balanceOf(address(this)) == 100, "bonds");
        require(usdc.balanceOf(BUSINESS) == 100 * 99_998_959, "spent");
        usdc.mint(address(zeno), 100 * (10 ** 6));
        uint256 beforeBal = usdc.balanceOf(address(this));
        zeno.redeem(100);
        returned = usdc.balanceOf(address(this)) - beforeBal;
        retained = usdc.balanceOf(address(zeno));
        require(returned == 100, "dust");
        require(retained == 100 * (10 ** 6) - 100, "face retained");
        require(zeno.balanceOf(address(this)) == 0, "burned");
        require(usdc.balanceOf(address(this)) == 104_200, "left");
    }
}
