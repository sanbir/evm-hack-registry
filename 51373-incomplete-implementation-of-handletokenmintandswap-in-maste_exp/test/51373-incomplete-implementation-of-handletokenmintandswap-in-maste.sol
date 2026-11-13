// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Entangle MasterSpotter.HandleTokenMintAndSwap decodes TokenMintAndSwap and
    returns. The body is `// TODO handle?` (Halborn, Entangle Trillion).
    SYNTHETIC, cheatcode-free.
    The payload says mint 1,000 tokens to the user. The buggy handler records
    the amount and credits 0. The control handler mints the 1,000. */

contract Bridged {
    string public symbol = "NGL";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Harm {
    string public symbol = "DROPPED";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract User {}

contract MasterSpotter {
    Bridged public token;
    uint256 public seenAmount;
    address public seenUser;

    constructor(address _token) {
        token = Bridged(_token);
    }

    function HandleTokenMintAndSwap(bytes calldata b) external returns (uint256 credited) {
        (,,,, bytes memory eventParams) = abi.decode(b, (bytes32, uint256, uint256, bytes32, bytes));
        (address recipient, uint256 amount) = abi.decode(eventParams, (address, uint256));
        seenUser = recipient;
        seenAmount = amount;
        // @> VULN: TokenMintAndSwap is decoded and then dropped
        credited = token.balanceOf(recipient);
    }
}

contract FixedSpotter {
    Bridged public token;

    constructor(address _token) {
        token = Bridged(_token);
    }

    function HandleTokenMintAndSwap(bytes calldata b) external returns (uint256 credited) {
        (,,,, bytes memory eventParams) = abi.decode(b, (bytes32, uint256, uint256, bytes32, bytes));
        (address recipient, uint256 amount) = abi.decode(eventParams, (address, uint256));
        credited = amount;
        token.mint(recipient, credited);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Harm public harm;
    Bridged public token;
    MasterSpotter public buggy;
    FixedSpotter public fixedSpotter;
    User public user;
    User public controlUser;

    uint256 public credited;
    uint256 public userBalance;
    uint256 public controlBalance;
    uint256 public dropped;

    constructor() {
        harm = new Harm();
        token = new Bridged();
        buggy = new MasterSpotter(address(token));
        fixedSpotter = new FixedSpotter(address(token));
        user = new User();
        controlUser = new User();
    }

    function _payload(address recipient) internal pure returns (bytes memory) {
        bytes memory eventParams = abi.encode(recipient, AMOUNT);
        return abi.encode(bytes32(0), uint256(1), uint256(1), bytes32("mint"), eventParams);
    }

    function run() external {
        require(AMOUNT == 1000 ether, "amount");
        credited = buggy.HandleTokenMintAndSwap(_payload(address(user)));
        require(buggy.seenAmount() == AMOUNT, "decoded");
        require(buggy.seenUser() == address(user), "user");
        require(credited == 0, "credited");
        userBalance = token.balanceOf(address(user));
        require(userBalance == 0, "not minted");
        controlBalance = fixedSpotter.HandleTokenMintAndSwap(_payload(address(controlUser)));
        require(controlBalance == AMOUNT, "control");
        require(token.balanceOf(address(controlUser)) == AMOUNT, "control user");
        dropped = controlBalance - userBalance;
        require(dropped == AMOUNT, "gap");
        harm.mint(SINK, dropped);
        require(harm.balanceOf(SINK) == AMOUNT, "marked");
    }
}
