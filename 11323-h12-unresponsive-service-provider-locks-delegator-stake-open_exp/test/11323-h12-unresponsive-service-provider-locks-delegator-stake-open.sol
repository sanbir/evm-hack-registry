// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Audius — an unresponsive service provider leaves claimPending true, so
    undelegateStake reverts (OpenZeppelin H12, finding 11323).
    SYNTHETIC, cheatcode-free, one block. The replay block is already past
    the undelegate lockup. lastClaimedFor is still behind the funded round,
    and only the service provider can call claimRewards. 1000 AUDIO cannot
    be withdrawn. The control lets anyone claim for the provider, then the
    delegator exits. */

contract Audio11323 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Staking11323 {
    mapping(address => uint256) public lastClaimed;

    function lastClaimedFor(address sp) external view returns (uint256) {
        return lastClaimed[sp];
    }

    function updateClaimHistory(address sp, uint256 blockNo) external {
        lastClaimed[sp] = blockNo;
    }
}

contract ServiceProviderFactory11323 {
    function getServiceProviderDetails(address)
        external
        pure
        returns (uint256, uint256, bool, uint256, uint256, uint256)
    {
        return (0, 0, true, 1, 0, 0);
    }
}

contract ClaimsManager11323 {
    Staking11323 public staking;
    ServiceProviderFactory11323 public spFactory;
    uint256 public fundBlock = 1;

    constructor(Staking11323 _staking, ServiceProviderFactory11323 _spFactory) {
        staking = _staking;
        spFactory = _spFactory;
    }

    function claimPending(address _sp) external view returns (bool pending) {
        uint256 lastClaimedForSP = staking.lastClaimedFor(_sp);
        (,,, uint256 numEndpoints,,) = spFactory.getServiceProviderDetails(_sp);
        return (lastClaimedForSP < fundBlock && numEndpoints > 0);
    }
}

contract DelegateManager11323 {
    struct UndelegateStakeRequest {
        uint256 lockupExpiryBlock;
        uint256 amount;
        address serviceProvider;
    }

    address public constant SP = address(uint160(0x2222));

    Audio11323 public token;
    ClaimsManager11323 public claimsManager;
    mapping(address => UndelegateStakeRequest) public undelegateRequests;

    constructor(Audio11323 _token, ClaimsManager11323 _claims) {
        token = _token;
        claimsManager = _claims;
    }

    function delegate(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        undelegateRequests[msg.sender] = UndelegateStakeRequest({
            lockupExpiryBlock: 50,
            amount: amount,
            serviceProvider: SP
        });
    }

    function _undelegateRequestIsPending(address delegator) internal view returns (bool) {
        return undelegateRequests[delegator].lockupExpiryBlock != 0
            && undelegateRequests[delegator].amount != 0
            && undelegateRequests[delegator].serviceProvider != address(0);
    }

    function _claimPending(address _sp) internal view returns (bool) {
        return claimsManager.claimPending(_sp);
    }

    function undelegateStake() external returns (uint256 unstakeAmount) {
        address delegator = msg.sender;
        require(_undelegateRequestIsPending(delegator), "Pending lockup expected");
        require(undelegateRequests[delegator].lockupExpiryBlock <= block.number, "Lockup must be expired");
        // @> VULN: an unresponsive SP never claims, so _claimPending stays true and this require reverts
        require(!_claimPending(undelegateRequests[delegator].serviceProvider), "Undelegate not permitted for SP pending claim");
        unstakeAmount = undelegateRequests[delegator].amount;
        token.transferFrom(address(this), delegator, unstakeAmount);
    }

    function claimRewardsFor(address sp) external {
        // absent on the vulnerable manager — only the SP could move the round forward
        sp;
        revert("only service provider");
    }
}

contract Exploit {
    uint256 public constant LOCKED = 1000 ether;

    Audio11323 public token;
    Staking11323 public staking;
    ServiceProviderFactory11323 public spFactory;
    ClaimsManager11323 public claims;
    DelegateManager11323 public mgr;

    constructor() {
        token = new Audio11323();
        staking = new Staking11323();
        spFactory = new ServiceProviderFactory11323();
        claims = new ClaimsManager11323(staking, spFactory);
        mgr = new DelegateManager11323(token, claims);
    }

    function run() external {
        require(block.number >= 50, "block must be past the lockup");
        token.mint(address(this), LOCKED);
        mgr.delegate(LOCKED);
        (bool ok, bytes memory ret) = address(mgr).call(abi.encodeCall(mgr.undelegateStake, ()));
        require(!ok, "undelegate should revert");
        bytes32 want = keccak256(abi.encodeWithSignature("Error(string)", "Undelegate not permitted for SP pending claim"));
        require(keccak256(ret) == want, "not the pending-claim revert");
        require(token.balanceOf(address(mgr)) == LOCKED, "stake still locked");
        require(token.balanceOf(address(this)) == 0, "delegator got nothing");
        require(claims.claimPending(address(uint160(0x2222))), "claim stays pending");
    }
}
