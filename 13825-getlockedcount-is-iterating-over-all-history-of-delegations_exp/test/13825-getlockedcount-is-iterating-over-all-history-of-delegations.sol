// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SKALE TokenState.getLockedCount walks every delegation a holder ever had
    (ConsenSys Diligence, SKALE token, Jan 2020).
    SYNTHETIC, cheatcode-free reduction. TokenState.sol L60-L71.
    The loop is unbounded. A transfer that calls it with a long history
    runs out of the gas a block will give it, so N cannot move.
    A precomputed locked total fits in the same gas and the holder withdraws N. */

contract TokenState {
    struct Delegation {
        address holder;
        uint256 amount;
        bool locked;
    }

    Delegation[] public delegations;
    mapping(address => uint256[]) public byHolder;
    mapping(address => uint256) public lockedTotal;
    mapping(address => uint256) public balanceOf;

    function mint(address holder, uint256 amount) external {
        balanceOf[holder] += amount;
    }

    function move(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function delegate(address holder, uint256 amount, bool locked) external {
        uint256 id = delegations.length;
        delegations.push(Delegation(holder, amount, locked));
        byHolder[holder].push(id);
        if (locked) {
            lockedTotal[holder] += amount;
        }
    }

    function getLockedCount(address holder) external view returns (uint256 amount) {
        uint256[] memory ids = byHolder[holder];
        for (uint256 i = 0; i < ids.length; ++i) {
            // @> VULN: every historical delegation is loaded; the list is unbounded and this runs on transfer
            Delegation memory d = delegations[ids[i]];
            if (d.locked) {
                amount += d.amount;
            }
        }
    }

    function getLockedCountBounded(address holder) external view returns (uint256) {
        return lockedTotal[holder];
    }
}

contract Wallet {
    TokenState public state;
    uint256 public constant STIPEND = 40000;

    constructor(address _state) {
        state = TokenState(_state);
    }

    function tryTransfer(address to, uint256 amount) external returns (bool moved) {
        (bool ok, bytes memory data) = address(state).call{gas: STIPEND}(
            abi.encodeWithSelector(state.getLockedCount.selector, msg.sender)
        );
        if (!ok || data.length < 32) {
            return false;
        }
        uint256 locked = abi.decode(data, (uint256));
        if (state.balanceOf(msg.sender) - locked < amount) {
            return false;
        }
        moved = true;
        emit Moved(to, amount);
    }

    function tryTransferBounded(address to, uint256 amount) external returns (bool moved) {
        (bool ok, bytes memory data) = address(state).call{gas: STIPEND}(
            abi.encodeWithSelector(state.getLockedCountBounded.selector, msg.sender)
        );
        if (!ok || data.length < 32) {
            return false;
        }
        uint256 locked = abi.decode(data, (uint256));
        if (state.balanceOf(msg.sender) - locked < amount) {
            return false;
        }
        state.move(msg.sender, to, amount);
        moved = true;
        emit Moved(to, amount);
    }

    event Moved(address to, uint256 amount);
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    uint256 public constant HISTORY = 48;

    TokenState public state;
    Wallet public wallet;
    address public sink;

    bool public vulnerableMoved;
    bool public controlMoved;
    uint256 public sinkBalance;

    constructor() {
        state = new TokenState();
        wallet = new Wallet(address(state));
        sink = address(new Sink());
        state.mint(address(this), N);
        for (uint256 i = 0; i < HISTORY; ++i) {
            state.delegate(address(this), 1, false);
        }
    }

    function run() external {
        vulnerableMoved = wallet.tryTransfer(sink, N);
        require(!vulnerableMoved, "vulnerable transfer");
        require(state.balanceOf(address(this)) == N, "still holding");
        controlMoved = wallet.tryTransferBounded(sink, N);
        require(controlMoved, "control");
        sinkBalance = state.balanceOf(sink);
        require(sinkBalance == N, "withdrawn");
        require(state.balanceOf(address(this)) == 0, "holder emptied");
    }
}

contract Sink {}
