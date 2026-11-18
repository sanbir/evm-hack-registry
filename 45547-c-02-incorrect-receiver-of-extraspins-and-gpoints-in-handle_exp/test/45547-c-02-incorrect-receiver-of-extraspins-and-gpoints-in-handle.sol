// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Guanciale Stake — extra spins and GPoints credited to msg.sender (Shieldify C-02, 45547)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: rawFulfillRandomWords is only callable by the VRF coordinator, but
    _handleRewardPayout writes extra spins and gPoints to msg.sender. The player
    stored on the spin request receives nothing. Vulnerable lines preserved (@> VULN). */

contract SpinToken {
    string public name = "ExtraSpin";
    string public symbol = "SPIN";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }
}

contract AmountTable {
    mapping(uint256 => uint256) public amounts;

    function set(uint256 id, uint256 v) external { amounts[id] = v; }

    function get(uint256 id) external view returns (uint256) { return amounts[id]; }
}

contract WheelOfGuantune {
    enum RewardType { ExtraSpins, GPoints }

    struct SpinRequest {
        address user;
        bool isFulfilled;
    }

    struct Layout {
        AmountTable[] extraSpinsOfRewardId;
        AmountTable[] gPointsOfRewardId;
        mapping(address => uint256) extraSpinsOfUser;
        mapping(address => uint256) gPointsOfUser;
        uint128 totalGPoints;
    }

    Layout internal $;
    mapping(uint256 => SpinRequest) public requests;
    uint256 public nextId;
    address public coordinator;
    SpinToken public spinToken;

    constructor(address _coordinator, SpinToken _spin) {
        coordinator = _coordinator;
        spinToken = _spin;
        AmountTable spins = new AmountTable();
        spins.set(1, 1);
        $.extraSpinsOfRewardId.push(spins);
        AmountTable points = new AmountTable();
        points.set(1, 5);
        $.gPointsOfRewardId.push(points);
    }

    function extraSpinsOfUser(address a) external view returns (uint256) { return $.extraSpinsOfUser[a]; }
    function gPointsOfUser(address a) external view returns (uint256) { return $.gPointsOfUser[a]; }
    function totalGPoints() external view returns (uint128) { return $.totalGPoints; }

    function spin() external returns (uint256 id) {
        id = ++nextId;
        requests[id] = SpinRequest({user: msg.sender, isFulfilled: false}); // STORY2
    }

    function rawFulfillRandomWords(uint256 requestId) external {
        require(msg.sender == coordinator, "only vrf");
        requests[requestId].isFulfilled = true;
        _handleRewardPayout(requests[requestId].user, 1, RewardType.ExtraSpins);
        _handleRewardPayout(requests[requestId].user, 1, RewardType.GPoints);
    }

    function _handleRewardPayout(address user, uint256 rewardId, RewardType rewardType) internal {
        user; // the spinning player is known here and then ignored
        if (rewardType == RewardType.ExtraSpins) {
            uint256 extraSpins = $.extraSpinsOfRewardId[$.extraSpinsOfRewardId.length - 1].get(rewardId);
            $.extraSpinsOfUser[msg.sender] += extraSpins; // @> VULN: credits the VRF coordinator, not user
            // FIX: $.extraSpinsOfUser[user] += extraSpins;
            spinToken.mint(msg.sender, extraSpins * 1e18);
        } else if (rewardType == RewardType.GPoints) {
            uint256 gPoints = $.gPointsOfRewardId[$.gPointsOfRewardId.length - 1].get(rewardId);
            $.gPointsOfUser[msg.sender] += gPoints; // @> VULN: gPoints follow msg.sender as well
            // FIX: $.gPointsOfUser[user] += gPoints;
            $.totalGPoints = uint128(uint256($.totalGPoints) + gPoints); // STORY5
        }
    }

    function getSpinRequest(uint256 id) external view returns (SpinRequest memory) { return requests[id]; }
}

contract Coordinator {
    function fulfill(WheelOfGuantune wheel, uint256 id) external {
        wheel.rawFulfillRandomWords(id); // STORY3
    }
}

contract Player {
    function spin(WheelOfGuantune wheel) external returns (uint256) { return wheel.spin(); }
}

contract Exploit {
    SpinToken public spin; // nonce 1
    Coordinator public coordinator; // nonce 2
    Player public player; // nonce 3
    WheelOfGuantune public wheel; // nonce 4

    constructor() {
        spin = new SpinToken();
        coordinator = new Coordinator();
        player = new Player();
        wheel = new WheelOfGuantune(address(coordinator), spin);
    }

    function run() external {
        uint256 id = player.spin(wheel); // STORY1
        require(wheel.getSpinRequest(id).user == address(player), "user");
        coordinator.fulfill(wheel, id); // STORY4
        require(wheel.extraSpinsOfUser(address(player)) == 0, "player got spins");
        require(wheel.gPointsOfUser(address(player)) == 0, "player got points");
        require(wheel.extraSpinsOfUser(address(coordinator)) == 1, "coordinator spins"); // STORY6
        require(wheel.gPointsOfUser(address(coordinator)) == 5, "coordinator points");
        require(spin.balanceOf(address(coordinator)) == 1 ether, "spin token");
        require(spin.balanceOf(address(player)) == 0, "player token");
    }
}
