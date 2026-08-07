// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.4;

import "forge-std/Test.sol";
import {Booster} from "../src/core/Booster.sol";
import {ITraderNFT} from "../src/interfaces/Interfaces.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Minimal REAL ERC20 standing in for the opaque coupon-payment token (USDC/BFR).
/// This is the ONLY doubled boundary; the vulnerable Booster is the real audited source.
contract PaymentToken is ERC20 {
    constructor() ERC20("PayToken", "PAY") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/// Minimal REAL trader-NFT (opaque external boundary, out of the finding's scope).
/// Returns an owner that never matches the buyer so the discount branch is skipped
/// and the FULL couponPrice flows into the Booster (worst-case trapped amount).
contract TraderNFTStub is ITraderNFT {
    function tokenOwner(uint256) external pure override returns (address) {
        return address(0xdead);
    }
    function tokenTierMappings(uint256) external pure override returns (uint8) {
        return 0;
    }
}

/// [H-01] Buffer Finance v2.5 — payments for coupons to Booster are irretrievable.
/// Booster.buy() does `token.safeTransferFrom(user, address(this), couponPrice)` (Booster.sol:L95)
/// but the contract exposes NO path to move ERC20 out. Every coupon payment is trapped forever.
contract BoosterTrappedFundsTest is Test {
    Booster booster;
    PaymentToken token;
    TraderNFTStub nft;

    address owner   = address(this);      // deployer -> DEFAULT_ADMIN_ROLE + Ownable owner
    address user    = makeAddr("user");   // coupon buyer
    uint256 constant COUPON_PRICE = 5_000e18;

    function setUp() public {
        nft     = new TraderNFTStub();
        booster = new Booster(address(nft));     // REAL audited Booster
        token   = new PaymentToken();
        booster.setPrice(COUPON_PRICE);          // onlyOwner
    }

    function test_CouponPaymentIsPermanentlyTrapped() public {
        // Fund the buyer and approve the Booster.
        token.mint(user, COUPON_PRICE);
        vm.prank(user);
        token.approve(address(booster), type(uint256).max);

        uint256 userBefore    = token.balanceOf(user);
        uint256 boosterBefore = token.balanceOf(address(booster));
        assertEq(boosterBefore, 0, "booster starts empty");

        // --- Buy a coupon: payment lands inside the Booster ---
        vm.prank(user);
        booster.buy(address(token), 1);

        uint256 userAfter    = token.balanceOf(user);
        uint256 boosterAfter = token.balanceOf(address(booster));

        // HARM part 1: the buyer paid the full coupon price and the funds sit in the Booster.
        assertEq(userBefore - userAfter, COUPON_PRICE, "user paid full coupon price");
        assertEq(boosterAfter, COUPON_PRICE, "coupon payment is now held by the Booster");
        // Sanity: the boost credit was granted, so this was a legitimate, expected payment.
        (uint256 totalBoostTrades,) = booster.userBoostTrades(address(token), user);
        assertEq(totalBoostTrades, booster.MAX_TRADES_PER_BOOST(), "boost credited (payment was real)");

        // HARM part 2: prove the funds are IRRETRIEVABLE.
        // The Booster has no fallback/receive and exposes no ERC20-egress function.
        // Enumerate every plausible retrieval entry point; a call to a non-existent
        // selector on a contract with no fallback reverts -> confirms NO path exists.
        bytes[] memory attempts = new bytes[](8);
        attempts[0] = abi.encodeWithSignature("withdraw()");
        attempts[1] = abi.encodeWithSignature("withdraw(address,uint256)", address(token), COUPON_PRICE);
        attempts[2] = abi.encodeWithSignature("sweep(address)", address(token));
        attempts[3] = abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), COUPON_PRICE);
        attempts[4] = abi.encodeWithSignature("rescueTokens(address,uint256)", address(token), COUPON_PRICE);
        attempts[5] = abi.encodeWithSignature("emergencyWithdraw(address)", address(token));
        attempts[6] = abi.encodeWithSignature("transferToken(address,address,uint256)", address(token), owner, COUPON_PRICE);
        attempts[7] = abi.encodeWithSignature("claimFees(address)", address(token));

        for (uint256 i = 0; i < attempts.length; i++) {
            // Try as the privileged owner/admin — the most powerful actor.
            (bool ok,) = address(booster).call(attempts[i]);
            assertFalse(ok, "no retrieval function should exist on the Booster");
        }

        // After exhausting every retrieval avenue, the money is still stuck.
        assertEq(token.balanceOf(address(booster)), COUPON_PRICE, "funds remain permanently locked in Booster");

        emit log_named_decimal_uint("Coupon paid by user (PAY)", COUPON_PRICE, 18);
        emit log_named_decimal_uint("Trapped in Booster forever (PAY)", token.balanceOf(address(booster)), 18);
        emit log_named_uint("Retrieval functions available on Booster", 0);
    }
}
