// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-39] AaveStrategy.sol: Changing swapper breaks the contract
    (Code4rena 2023-07-tapioca, reporter carrotsmuggler, finding #27529).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: AaveStrategy constructor grants infinite rewardToken allowance
    to multiSwapper, but setMultiSwapper only updates the swapper pointer and
    never revokes the old allowance or approves the new swapper. After an
    upgrade, compound()'s swapper.swap → transferFrom fails for lack of
    allowance, so compounding (and any withdrawal path that compounds first)
    is permanently bricked until someone re-approves off-band.

    Blamed setMultiSwapper body preserved with @> VULN.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

interface ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to) external returns (uint256);
}

/// @notice Honest swapper: pulls rewardToken and pays wrappedNative 1:1.
contract HonestSwapper is ISwapper {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, address to) external returns (uint256) {
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockERC20(tokenOut).mint(to, amountIn);
        return amountIn;
    }
}

/// @notice Reduced AaveStrategy: holds rewardToken, swaps to wrappedNative on compound.
contract AaveStrategy {
    address public owner;
    MockERC20 public rewardToken;
    MockERC20 public wrappedNative;
    ISwapper public swapper;

    event MultiSwapper(address indexed oldSwapper, address indexed newSwapper);

    constructor(MockERC20 _reward, MockERC20 _wNative, address _multiSwapper) {
        owner = msg.sender;
        rewardToken = _reward;
        wrappedNative = _wNative;
        swapper = ISwapper(_multiSwapper);
        // Constructor correctly approves the initial swapper:
        rewardToken.approve(_multiSwapper, type(uint256).max);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    /// @dev Verbatim reduction of the broken setter (no approve/revoke).
    function setMultiSwapper(address _swapper) external onlyOwner {
        emit MultiSwapper(address(swapper), _swapper);
        // @> VULN: updates pointer only — never approve(_swapper) / revoke old.
        // FIX: rewardToken.approve(address(swapper), 0); swapper = ISwapper(_swapper);
        //      rewardToken.approve(_swapper, type(uint256).max);
        swapper = ISwapper(_swapper);
    }

    /// @dev Reduced compound: swap all rewardToken into wrappedNative via swapper.
    function compound() external returns (uint256 out) {
        uint256 bal = rewardToken.balanceOf(address(this));
        require(bal > 0, "no rewards");
        out = swapper.swap(address(rewardToken), address(wrappedNative), bal, address(this));
    }
}

contract Exploit {
    MockERC20 public rewardToken;
    MockERC20 public wrappedNative;
    HonestSwapper public oldSwapper;
    HonestSwapper public newSwapper;
    AaveStrategy public strategy;

    uint256 public constant REWARDS = 100 ether;
    bool public compoundBroken;

    constructor() {
        rewardToken = new MockERC20("AAVE", "AAVE");
        wrappedNative = new MockERC20("WETH", "WETH");
        oldSwapper = new HonestSwapper();
        newSwapper = new HonestSwapper();
        strategy = new AaveStrategy(rewardToken, wrappedNative, address(oldSwapper));

        // Seed strategy with claimable rewards (as if incentivesController paid).
        rewardToken.mint(address(strategy), REWARDS);
    }

    function run() external {
        // Baseline: old swapper works (allowance set in constructor).
        // Transfer rewards out path would succeed — we re-mint after control.
        // Actually demonstrate by attempting compound after broken upgrade.

        // Owner upgrades multiSwapper without re-approving (the bug).
        strategy.setMultiSwapper(address(newSwapper));

        // New swapper has ZERO allowance — compound must fail.
        (bool ok, ) = address(strategy).call(abi.encodeWithSelector(AaveStrategy.compound.selector));
        compoundBroken = !ok;
        require(compoundBroken, "harm: compound must revert after swapper change");
        require(rewardToken.balanceOf(address(strategy)) == REWARDS, "harm: rewards still stuck");
        require(wrappedNative.balanceOf(address(strategy)) == 0, "harm: no WETH compounded");
        // Allowance still points at the OLD swapper, not the new one.
        require(rewardToken.allowance(address(strategy), address(newSwapper)) == 0, "new has no allow");
        require(rewardToken.allowance(address(strategy), address(oldSwapper)) == type(uint256).max, "old still max");
    }
}
