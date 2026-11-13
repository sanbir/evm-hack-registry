// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Mystic stPlumeMinter — validator unstake returns before writing the request
    (Kann, Mystic Finance RWA, 2025-06, finding 4.1.2).
    SYNTHETIC, cheatcode-free. The early return is the audited path.

    currentWithheldETH is 0, so unstakeFromValidator burns 10 frxETH, pulls 10
    WETH off the validator, and returns amountUnstaked without storing
    withdrawalRequests[msg.sender]. withdraw() reads a zero request and pays 0.
    The 10 WETH stays in the minter. No vm.warp. */

contract Asset {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Validator {
    Asset public WETH;

    constructor(Asset weth_) {
        WETH = weth_;
    }

    function release(address to, uint256 amount) external {
        WETH.transfer(to, amount);
    }
}

contract StPlumeMinter {
    struct WithdrawalRequest {
        uint256 amount;
        uint256 timestamp;
    }

    Asset public frxETH;
    Asset public WETH;
    Validator public plume;
    uint256 public currentWithheldETH;
    mapping(address => WithdrawalRequest) public withdrawalRequests;

    constructor(Asset frx, Asset weth_, Validator plume_) {
        frxETH = frx;
        WETH = weth_;
        plume = plume_;
    }

    function unstakeFromValidator(uint256 amount, uint16 validatorId) external virtual returns (uint256 amountUnstaked) {
        amountUnstaked = _unstake(amount, validatorId);
    }

    /// @dev Verbatim shape of the audited `_unstake` validator branch.
    function _unstake(uint256 amount, uint16 _validatorId) internal returns (uint256 amountUnstaked) {
        require(amount > 0, "Amount must be greater than 0");
        frxETH.burn(msg.sender, amount);
        require(withdrawalRequests[msg.sender].amount == 0, "Withdrawal already requested");

        if (currentWithheldETH >= amount) {
            amountUnstaked = amount;
        } else {
            uint256 remainingToUnstake = amount;
            amountUnstaked = 0;
            if (_validatorId != 0) {
                amountUnstaked += remainingToUnstake;
                plume.release(address(this), remainingToUnstake);
                uint256 returned = amountUnstaked;
                // @> VULN: return amountUnstaked before withdrawalRequests[msg.sender] is written
                return returned;
            }
        }
        withdrawalRequests[msg.sender] = WithdrawalRequest({amount: amountUnstaked, timestamp: block.timestamp});
        return amountUnstaked;
    }

    function withdraw(address recipient) external returns (uint256 amount) {
        WithdrawalRequest storage request = withdrawalRequests[msg.sender];
        amount = request.amount;
        request.amount = 0;
        request.timestamp = 0;
        if (amount > 0) WETH.transfer(recipient, amount);
    }

    function requestOf(address who) external view returns (uint256) {
        return withdrawalRequests[who].amount;
    }
}

contract StPlumeMinterFixed is StPlumeMinter {
    constructor(Asset frx, Asset weth_, Validator plume_) StPlumeMinter(frx, weth_, plume_) {}

    function unstakeFromValidator(uint256 amount, uint16 validatorId) external override returns (uint256 amountUnstaked) {
        require(amount > 0, "Amount must be greater than 0");
        frxETH.burn(msg.sender, amount);
        amountUnstaked = amount;
        plume.release(address(this), amount);
        withdrawalRequests[msg.sender] = WithdrawalRequest({amount: amountUnstaked, timestamp: block.timestamp});
        validatorId;
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 10 ether;

    Asset public frxETH; // nonce 1
    Asset public weth; // nonce 2
    Validator public plume; // nonce 3
    StPlumeMinter public minter; // nonce 4

    uint256 public burned;
    uint256 public requestAmount;
    uint256 public paid;
    uint256 public stuck;

    constructor() {
        frxETH = new Asset("frxETH", "frxETH");
        weth = new Asset("WETH", "WETH");
        plume = new Validator(weth);
        minter = new StPlumeMinter(frxETH, weth, plume);
        frxETH.mint(address(this), AMOUNT);
        weth.mint(address(plume), AMOUNT);
    }

    function run() external {
        burned = frxETH.balanceOf(address(this));
        minter.unstakeFromValidator(AMOUNT, 1);
        burned = AMOUNT - frxETH.balanceOf(address(this));
        requestAmount = minter.requestOf(address(this));
        paid = minter.withdraw(address(this));
        stuck = weth.balanceOf(address(minter));
        require(burned == AMOUNT, "10 frxETH burned");
        require(requestAmount == 0, "request missing");
        require(paid == 0, "no ETH returned");
        require(stuck == AMOUNT, "10 WETH stuck");
        require(weth.balanceOf(address(this)) == 0, "user got nothing");
    }
}
