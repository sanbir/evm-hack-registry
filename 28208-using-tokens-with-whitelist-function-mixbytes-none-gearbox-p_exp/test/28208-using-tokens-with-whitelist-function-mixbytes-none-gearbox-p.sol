// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Gearbox V1 — whitelist token liquidation credits value that never moves
    (MixBytes, finding #28208).
    SYNTHETIC, cheatcode-free reduction.
    _transferAssetsTo always does totalValue += tv after _safeTokenTransfer.
    _safeTokenTransfer swallows a revert when force is true (the blocked-token
    path). A whitelist token reverts for a non-whitelisted recipient, so the
    tokens stay in the credit account while the liquidator is still charged tv.
    The blamed add is preserved verbatim (@> VULN). */

contract Underlying {
    string public name = "DAI";
    string public symbol = "DAI";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WhitelistToken {
    string public name = "Whitelist USD";
    string public symbol = "WUSD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public allowed;
    address public immutable minter;

    error NotWhitelisted();

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (!allowed[msg.sender] || !allowed[to]) revert NotWhitelisted();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PlainToken {
    string public name = "Plain USD";
    string public symbol = "PUSD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CreditAccount {
    address public manager;

    function setManager(address who) external {
        require(manager == address(0), "set");
        manager = who;
    }

    function safeTransfer(address token, address to, uint256 amount) external {
        require(msg.sender == manager, "manager");
        require(TokenLike(token).transfer(to, amount), "transfer");
    }
}

interface TokenLike {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract CreditManager {
    Underlying public immutable underlying;
    /// Storage so viaIR cannot delete the force check or the totalValue add.
    bool public forceOn;
    uint256 public totalValue;

    constructor(Underlying _underlying) {
        underlying = _underlying;
        forceOn = true;
    }

    function setForce(bool v) external {
        forceOn = v;
    }

    function liquidate(
        address creditAccount,
        address token,
        address to,
        uint256 amount,
        uint256 tv,
        bool force
    ) external returns (uint256 quoted) {
        if (amount > 1) {
            _safeTokenTransfer(creditAccount, token, to, amount - 1, force);
            totalValue = 0;
            // External self-call so the add is its own frame. viaIR was folding
            // `totalValue += tv` into a neighboring statement.
            quoted = this.note(tv);
            underlying.transferFrom(msg.sender, address(this), quoted);
        }
    }

    /// @notice The audited add. Called externally so the write cannot be inlined away.
    function note(uint256 tv) external returns (uint256) {
        require(msg.sender == address(this), "self");
        // @> VULN: totalValue grows even when the whitelist transfer reverted and the tokens did not move
        // FIX: add tv only after a successful transfer; on a caught failure leave totalValue unchanged
        totalValue += tv;
        return totalValue;
    }

    /// Gearbox skips the revert only when force is true, then the caller still
    /// counts the token. The WETH unwrap branch is not part of this finding.
    function _safeTokenTransfer(
        address creditAccount,
        address token,
        address to,
        uint256 amount,
        bool force
    ) internal {
        try CreditAccount(creditAccount).safeTransfer(token, to, amount) {} catch {
            require(force && forceOn, "CM_TRANSFER_FAILED");
        }
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1_000 ether;

    Underlying public underlying;
    WhitelistToken public wl;
    PlainToken public plain;
    CreditAccount public wlAccount;
    CreditAccount public plainAccount;
    CreditManager public manager;
    uint256 public stuck;
    uint256 public charged;
    uint256 public controlReceived;

    constructor() {
        underlying = new Underlying();
        wl = new WhitelistToken();
        plain = new PlainToken();
        wlAccount = new CreditAccount();
        plainAccount = new CreditAccount();
        manager = new CreditManager(underlying);
        wlAccount.setManager(address(manager));
        plainAccount.setManager(address(manager));
        underlying.mint(address(this), AMOUNT * 2);
    }

    function run() external {
        wl.mint(address(wlAccount), AMOUNT);
        plain.mint(address(plainAccount), AMOUNT);
        underlying.approve(address(manager), AMOUNT * 2);
        charged = manager.liquidate(address(wlAccount), address(wl), address(this), AMOUNT, AMOUNT, true);
        stuck = wl.balanceOf(address(wlAccount));
        require(stuck == AMOUNT, "whitelist tokens are not stuck");
        require(wl.balanceOf(address(this)) == 0, "non-whitelisted address was credited");
        require(charged == AMOUNT, "totalValue ignored the failed transfer");
        require(underlying.balanceOf(address(manager)) == AMOUNT, "liquidator was not charged");
        uint256 controlQuote =
            manager.liquidate(address(plainAccount), address(plain), address(this), AMOUNT, AMOUNT, true);
        controlReceived = plain.balanceOf(address(this));
        require(controlReceived == AMOUNT - 1, "control transfer did not succeed");
        require(plain.balanceOf(address(plainAccount)) == 1, "control did not leave the 1 wei dust");
        require(controlQuote == AMOUNT, "control quote mismatch");
    }

    /// Same manager, plain token, no whitelist. The transfer succeeds.
    function runControl() external {
        plain.mint(address(plainAccount), AMOUNT);
        underlying.approve(address(manager), AMOUNT);
        uint256 quoted =
            manager.liquidate(address(plainAccount), address(plain), address(this), AMOUNT, AMOUNT, true);
        controlReceived = plain.balanceOf(address(this));
        require(controlReceived == AMOUNT - 1, "control transfer did not succeed");
        require(quoted == AMOUNT, "control quote");
        require(underlying.balanceOf(address(manager)) == AMOUNT, "payment");
    }
}
