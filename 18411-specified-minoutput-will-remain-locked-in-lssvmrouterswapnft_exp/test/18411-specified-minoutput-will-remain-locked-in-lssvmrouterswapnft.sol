// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Sudoswap LSSVMRouter — specified `minOutput` remains locked in the router
    (Cyfrin review, finding #18411, reporter Hans) — HIGH / frozen-funds

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The vulnerable
    LSSVMRouter.swapNFTsForSpecificNFTsThroughETH keeps the exact minOutput
    deduction (`outputAmount - minOutput` passed as the ETH->NFT input) VERBATIM,
    and _swapETHForSpecificNFTs keeps the refund-based-on-the-reduced-inputAmount
    logic VERBATIM. The Exploit deploys everything, a user (Alice) does a legit
    NFT-for-specific-NFT swap while protecting herself with a non-zero minOutput,
    and ends up with `minOutput` worth of value permanently stuck in the router.

    Native ETH is modeled as a WETH ERC20 (the browser @ethereumjs/vm has no
    Foundry cheatcodes, so value cannot be dealt/minted as native balance). This
    changes only the transfer medium (`weth.transfer(...)` in place of
    `ethRecipient.safeTransferETH(...)`); the load-bearing vulnerable arithmetic
    — `outputAmount - minOutput` — is preserved byte-for-byte.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used to model native ETH / WETH (the swap medium).
contract MockWETH {
    string public constant name = "Wrapped Ether (mock)";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal ERC721 (only what the swap path needs).
contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => address) public getApproved;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address operator, bool ok) external {
        isApprovedForAll[msg.sender][operator] = ok;
    }

    function approve(address to, uint256 id) external {
        require(msg.sender == ownerOf[id], "not owner");
        getApproved[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "wrong owner");
        require(
            msg.sender == from || isApprovedForAll[from][msg.sender] || getApproved[id] == msg.sender,
            "not approved"
        );
        ownerOf[id] = to;
        getApproved[id] = address(0);
    }
}

/// @notice Reduced Sudoswap pair. `swapNFTsForToken` sells NFTs to the pool for
///         WETH (paid to the router); `swapTokenForSpecificNFTs` sells specific
///         NFTs out of the pool for WETH (pulled from the router).
contract MockPair {
    MockNFT public immutable nft;
    MockWETH public immutable weth;
    uint256 public immutable spotPrice; // WETH cost to buy one NFT out of the pool
    uint256 public immutable salePrice; // WETH paid when selling one NFT into the pool

    constructor(MockNFT _nft, MockWETH _weth, uint256 _spotPrice, uint256 _salePrice) {
        nft = _nft;
        weth = _weth;
        spotPrice = _spotPrice;
        salePrice = _salePrice;
    }

    /// @notice Sell `ids` into the pool. The pool pulls each NFT from its current
    ///         owner (who approved the pool) and pays `salePrice` WETH per NFT to
    ///         `tokenRecipient` (the router in the NFT->NFT flow).
    function swapNFTsForToken(uint256[] calldata ids, uint256 minOutput, address tokenRecipient)
        external
        returns (uint256 outputAmount)
    {
        for (uint256 i; i < ids.length; ++i) {
            nft.transferFrom(nft.ownerOf(ids[i]), address(this), ids[i]);
        }
        outputAmount = salePrice * ids.length;
        require(outputAmount >= minOutput, "outputAmount too low");
        weth.transfer(tokenRecipient, outputAmount);
    }

    /// @notice Quote the cost to buy `numItems` NFTs out of the pool.
    function getBuyNFTQuote(uint256, uint256 numItems) external view returns (uint256) {
        return spotPrice * numItems;
    }

    /// @notice Buy specific `ids` out of the pool. Pulls the exact `cost` WETH
    ///         from the caller (router) and sends the NFTs to `nftRecipient`.
    function swapTokenForSpecificNFTs(uint256[] calldata ids, uint256 maxCost, address nftRecipient)
        external
        returns (uint256 cost)
    {
        cost = spotPrice * ids.length;
        require(cost <= maxCost, "cost too high"); // real: "Bonding curve error"/maxCost guard
        weth.transferFrom(msg.sender, address(this), cost);
        for (uint256 i; i < ids.length; ++i) {
            nft.transferFrom(address(this), nftRecipient, ids[i]);
        }
    }
}

/// @notice Reduced LSSVMRouter. `swapNFTsForSpecificNFTsThroughETH` and
///         `_swapETHForSpecificNFTs` are faithful reductions of
///         https://github.com/sudoswap/lssvm2/blob/78d38753b2042d7813132f26e5573c6699b605ef/src/LSSVMRouter.sol
///         with the vulnerable minOutput deduction and refund logic preserved.
contract LSSVMRouter {
    struct PairSwapSpecific {
        MockPair pair;
        uint256[] nftIds;
    }

    struct NFTsForSpecificNFTsTrade {
        PairSwapSpecific[] nftToTokenTrades;
        PairSwapSpecific[] tokenToNFTTrades;
    }

    MockWETH public immutable weth;

    constructor(MockWETH _weth) {
        weth = _weth;
    }

    /**
     * @notice Swaps one set of NFTs into another set of specific NFTs using multiple pairs, using
     *     ETH as the intermediary.
     *     @param minOutput The minimum acceptable total excess ETH received
     *     @return outputAmount The total ETH received
     */
    function swapNFTsForSpecificNFTsThroughETH(
        NFTsForSpecificNFTsTrade calldata trade,
        uint256 minOutput,
        address ethRecipient,
        address nftRecipient,
        uint256 msgValue // models the payable msg.value: attached ETH, pulled here as WETH from the caller
    ) external returns (uint256 outputAmount) {
        // caller "attaches" msgValue ETH to the call (modeled as WETH pulled from the caller)
        weth.transferFrom(msg.sender, address(this), msgValue);

        // Swap NFTs for ETH
        // minOutput of swap set to 0 since we're doing an aggregate slippage check
        outputAmount = _swapNFTsForToken(trade.nftToTokenTrades, 0, address(this));

        // Add extra value to buy NFTs
        outputAmount += msgValue; // was: outputAmount += msg.value;

        // Swap ETH for specific NFTs
        // cost <= inputValue = outputAmount - minOutput, so outputAmount' = (outputAmount - minOutput - cost) + minOutput >= minOutput
        outputAmount = _swapETHForSpecificNFTs(
            trade.tokenToNFTTrades, outputAmount - minOutput, ethRecipient, nftRecipient // @> VULN: minOutput is subtracted from the ETH->NFT input; the refund below is computed from this ALREADY-REDUCED amount, so the minOutput excess is never refunded and stays locked in the router forever. FIX: pass minOutput through to the refund calc: _swapETHForSpecificNFTs(trade.tokenToNFTTrades, outputAmount, ...) and validate the surplus >= minOutput.
        ) + minOutput;
    }

    /// @notice Sell every nftToToken trade's NFTs into its pool for WETH, credited
    ///         to `tokenRecipient`. Aggregate slippage checked against `minOutput`.
    function _swapNFTsForToken(PairSwapSpecific[] calldata swapList, uint256 minOutput, address tokenRecipient)
        internal
        returns (uint256 outputAmount)
    {
        uint256 numSwaps = swapList.length;
        for (uint256 i; i < numSwaps;) {
            // minExpectedTokenOutput is set to 0 since we're doing an aggregate slippage check below
            outputAmount += swapList[i].pair.swapNFTsForToken(swapList[i].nftIds, 0, tokenRecipient);
            unchecked {
                ++i;
            }
        }
        // Aggregate slippage check
        require(outputAmount >= minOutput, "outputAmount too low");
    }

    /**
     * @notice Internal function used to swap ETH for a specific set of NFTs.
     *     @param inputAmount The total amount of ETH to send (here: outputAmount - minOutput)
     *     @return remainingValue The unspent token amount
     */
    function _swapETHForSpecificNFTs(
        PairSwapSpecific[] calldata swapList,
        uint256 inputAmount,
        address ethRecipient,
        address nftRecipient
    ) internal returns (uint256 remainingValue) {
        remainingValue = inputAmount; // seeded with the ALREADY-REDUCED (outputAmount - minOutput)

        uint256 pairCost;

        // Do swaps
        uint256 numSwaps = swapList.length;
        for (uint256 i; i < numSwaps;) {
            // Calculate the cost per swap first to send exact amount of ETH over
            pairCost = swapList[i].pair.getBuyNFTQuote(swapList[i].nftIds[0], swapList[i].nftIds.length);

            // approve the pool to pull the exact cost (models the router sending {value: pairCost})
            weth.approve(address(swapList[i].pair), pairCost);

            // Total ETH taken from sender cannot exceed inputAmount
            // because otherwise the deduction from remainingValue will fail
            remainingValue -= swapList[i].pair.swapTokenForSpecificNFTs(
                swapList[i].nftIds, remainingValue, nftRecipient
            );

            unchecked {
                ++i;
            }
        }

        // Return remaining value to sender — computed from the reduced inputAmount,
        // so the minOutput slice never makes it into this refund.
        if (remainingValue > 0) {
            weth.transfer(ethRecipient, remainingValue); // was: ethRecipient.safeTransferETH(remainingValue);
        }
    }
}

/// @dev The user (victim). Sells one NFT and buys a specific NFT through the
///      router in a single call, protecting against slippage with a non-zero
///      minOutput — and unwittingly locks that minOutput slice in the router.
contract Exploit {
    // Prices chosen so the ETH->NFT input (outputAmount - minOutput) never
    // underflows; the exact magnitudes validate the reduced model.
    uint256 public constant MSG_VALUE = 1 ether; // ETH attached to the swap
    uint256 public constant MIN_OUTPUT = 0.79 ether; // user's slippage floor -> the amount that gets stuck
    uint256 public constant SPOT_PRICE = 0.9 ether; // cost to buy the specific NFT
    uint256 public constant SALE_PRICE = 0.9 ether; // proceeds from selling the user's NFT

    uint256 public constant SELL_ID = 1; // NFT the user sells
    uint256 public constant BUY_ID = 4; // NFT the user wants to buy

    MockWETH public weth;
    MockNFT public nft;
    MockPair public pair;
    LSSVMRouter public router;
    address public alice;

    // recorded for the harm assertions
    uint256 public aliceRefund;
    uint256 public routerLocked;

    constructor() {
        // deploy order (CREATE nonces): 1=weth, 2=nft, 3=pair, 4=router
        weth = new MockWETH(); // nonce 1
        nft = new MockNFT(); // nonce 2
        pair = new MockPair(nft, weth, SPOT_PRICE, SALE_PRICE); // nonce 3
        router = new LSSVMRouter(weth); // nonce 4

        // This contract acts as the user "Alice".
        alice = address(this);

        // Pool inventory: the pool owns the NFT Alice will buy, and holds WETH so
        // it can pay Alice's sale proceeds.
        nft.mint(address(pair), BUY_ID);
        weth.mint(address(pair), 100 ether);

        // Alice owns the NFT she will sell, and holds the ETH (WETH) she attaches.
        nft.mint(alice, SELL_ID);
        weth.mint(alice, MSG_VALUE);

        // Approvals: pool pulls Alice's sold NFT; router pulls Alice's attached WETH.
        nft.setApprovalForAll(address(pair), true);
        weth.approve(address(router), type(uint256).max);
    }

    function run() external {
        // Build the NFT-for-specific-NFT trade: sell SELL_ID, buy BUY_ID.
        uint256[] memory sellIds = new uint256[](1);
        sellIds[0] = SELL_ID;
        uint256[] memory buyIds = new uint256[](1);
        buyIds[0] = BUY_ID;

        LSSVMRouter.PairSwapSpecific[] memory nftToToken = new LSSVMRouter.PairSwapSpecific[](1);
        nftToToken[0] = LSSVMRouter.PairSwapSpecific({pair: pair, nftIds: sellIds});

        LSSVMRouter.PairSwapSpecific[] memory tokenToNFT = new LSSVMRouter.PairSwapSpecific[](1);
        tokenToNFT[0] = LSSVMRouter.PairSwapSpecific({pair: pair, nftIds: buyIds});

        LSSVMRouter.NFTsForSpecificNFTsTrade memory trade =
            LSSVMRouter.NFTsForSpecificNFTsTrade({nftToTokenTrades: nftToToken, tokenToNFTTrades: tokenToNFT});

        // Alice protects herself with a non-zero minOutput and does the swap.
        router.swapNFTsForSpecificNFTsThroughETH(trade, MIN_OUTPUT, alice, alice, MSG_VALUE);

        aliceRefund = weth.balanceOf(alice);
        routerLocked = weth.balanceOf(address(router));

        // === HARM ===
        // The swap "succeeded": Alice received the specific NFT she paid for.
        require(nft.ownerOf(BUY_ID) == alice, "alice did not receive the bought NFT");

        // Yet exactly `minOutput` worth of value is now stranded in the router,
        // unreachable by any function — permanently locked (frozen funds).
        require(routerLocked == MIN_OUTPUT, "minOutput not locked in router");

        // Alice was shorted by exactly that amount: a correct router would have
        // refunded the full surplus (sale proceeds + attached value - buy cost =
        // 0.9 + 1.0 - 0.9 = 1.0 WETH); instead she got 1.0 - minOutput = 0.21.
        uint256 fairRefund = (SALE_PRICE + MSG_VALUE) - SPOT_PRICE; // 1.0 ether
        require(aliceRefund == fairRefund - MIN_OUTPUT, "unexpected refund"); // 0.21 ether
        require(fairRefund - aliceRefund == MIN_OUTPUT, "shortfall != locked amount"); // she lost exactly minOutput
    }
}
