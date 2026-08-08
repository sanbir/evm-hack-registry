// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// =============================================================================
//  IntentX StakedINTX — pending rewards can never be paid out
//  (Quantstamp, intent-x, StakedINTX.sol claim()).
//
//  claim() reads the caller's accrued rewards into `_amountOut` BEFORE the
//  local `_owner` address is assigned to `_ownerOf(_tokenId)`. Because `_owner`
//  is still the zero address at that point, `_amountOut` is initialized to
//  `pendingRewards[address(0)]` (== 0) instead of the caller's real pending
//  balance. Later the function resets `pendingRewards[_owner]` to 0, so the
//  staker's accrued rewards are wiped WITHOUT ever being transferred — a
//  permanent self-loss of their own rewards.
//
//  claim() is reproduced VERBATIM in its ordering (buggy line marked @>); the
//  reward token, the per-token accrual, and the `_ownerOf` double are faithful
//  minimal doubles. Local deploy, no fork, no cheatcodes.
// =============================================================================

contract MiniToken {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/*//////////////////////////////////////////////////////////////
   StakedINTX — VULNERABLE. claim() reads pendingRewards[_owner]
   while `_owner` is still the zero address, then wipes the
   caller's pending balance without paying it out.
//////////////////////////////////////////////////////////////*/
contract StakedINTX {
    MiniToken public rewardToken;

    // The caller's accrued (off-chain-computed) pending rewards.
    mapping(address => uint256) public pendingRewards;
    // Per-xINTX-token reward accrual, keyed by tokenId.
    mapping(uint256 => uint256) public tokenRewards;

    constructor(MiniToken _rewardToken) {
        rewardToken = _rewardToken;
    }

    function setPendingRewards(address who, uint256 amt) external {
        pendingRewards[who] = amt;
    }

    function setTokenRewards(uint256 tokenId, uint256 amt) external {
        tokenRewards[tokenId] = amt;
    }

    // Faithful double: the xINTX token owner is the caller.
    function _ownerOf(uint256) internal view returns (address) {
        return msg.sender;
    }

    function claim(uint256 _tokenId) external returns (uint256) {
        address _owner;
        uint256 _amountOut = pendingRewards[_owner]; // @> reads pendingRewards[address(0)] == 0, not the caller's balance
        // add up the rewards of the xINTX token to the (wrongly-zero) pending total
        _amountOut += tokenRewards[_tokenId];
        _owner = _ownerOf(_tokenId); // _owner set to caller only AFTER the read above
        pendingRewards[_owner] = 0; // caller's real pending balance wiped, never included in _amountOut
        rewardToken.transfer(_owner, _amountOut);
        return _amountOut;
    }
}

/*//////////////////////////////////////////////////////////////
   StakedINTXFixed — assign `_owner` to the caller BEFORE reading
   pendingRewards, so the accrued balance is actually paid out.
//////////////////////////////////////////////////////////////*/
contract StakedINTXFixed {
    MiniToken public rewardToken;

    mapping(address => uint256) public pendingRewards;
    mapping(uint256 => uint256) public tokenRewards;

    constructor(MiniToken _rewardToken) {
        rewardToken = _rewardToken;
    }

    function setPendingRewards(address who, uint256 amt) external {
        pendingRewards[who] = amt;
    }

    function setTokenRewards(uint256 tokenId, uint256 amt) external {
        tokenRewards[tokenId] = amt;
    }

    function _ownerOf(uint256) internal view returns (address) {
        return msg.sender;
    }

    function claim(uint256 _tokenId) external returns (uint256) {
        address _owner = _ownerOf(_tokenId); // FIX: resolve caller first
        uint256 _amountOut = pendingRewards[_owner]; // now reads the caller's real pending balance
        _amountOut += tokenRewards[_tokenId];
        pendingRewards[_owner] = 0;
        rewardToken.transfer(_owner, _amountOut);
        return _amountOut;
    }
}

/*//////////////////////////////////////////////////////////////
   Exploit — a staker with accrued pending rewards calls claim()
   and receives NOTHING, while their pending balance is zeroed.
   The wiped rewards are a permanent self-loss → minted to SINK.
//////////////////////////////////////////////////////////////*/
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d; // user-loss sink
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant PENDING = 1_000 ether; // staker's accrued pending rewards
    uint256 internal constant TOKEN_ID = 7;

    MiniToken public rewardToken;
    StakedINTX public staking;
    MiniToken public lossMarker;

    uint256 public pendingBefore;
    uint256 public pendingAfter;
    uint256 public received; // reward tokens actually paid to the staker
    uint256 public lost; // pending rewards wiped without payout

    function run() external payable {
        rewardToken = new MiniToken("INTX");
        staking = new StakedINTX(rewardToken);
        lossMarker = new MiniToken("LOST-INTX");

        // Fund the staking contract so it COULD pay out the full pending balance.
        rewardToken.mint(address(staking), PENDING);

        // The staker (this contract) has accrued PENDING rewards; the xINTX
        // token itself has no extra per-token accrual.
        staking.setPendingRewards(address(this), PENDING);
        staking.setTokenRewards(TOKEN_ID, 0);

        pendingBefore = staking.pendingRewards(address(this));

        // Staker claims — msg.sender (this contract) is the token owner.
        staking.claim(TOKEN_ID);

        received = rewardToken.balanceOf(address(this));
        pendingAfter = staking.pendingRewards(address(this));

        // Pending went from PENDING -> 0 but nothing was transferred: pure loss.
        lost = pendingBefore - pendingAfter;
        lossMarker.mint(SINK, lost);
    }
}
