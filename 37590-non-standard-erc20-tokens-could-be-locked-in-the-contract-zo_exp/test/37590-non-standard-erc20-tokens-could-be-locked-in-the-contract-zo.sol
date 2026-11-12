// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Cyber Finance — Non-standard ERC20 rewards lock (Zokyo, finding 37590)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    withdrawReward calls IERC20.transfer and requires a bool. A token that
    returns no data reverts that call, so 1000 stays in the distributor and
    the owner receives 0. A 10% fee token returns false when the distributor
    tries to send the credited 1000 (only 900 arrived), so 900 stays and the
    owner receives 0. The same function with a standard token pays the owner
    1000. The blamed transfer is preserved verbatim (@> VULN). run() does not
    warp. */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract NoReturnToken {
    string public name = "No Return Reward";
    string public symbol = "NRWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // USDT-style: transfer succeeds and returns no bool.
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
    }
}

contract FeeToken {
    string public name = "Fee Reward";
    string public symbol = "FRWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) return false;
        uint256 fee = amount / 10;
        uint256 net = amount - fee;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += net;
        totalSupply -= fee;
        emit Transfer(msg.sender, to, net);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (balanceOf[from] < amount) return false;
        allowance[from][msg.sender] = allowed - amount;
        uint256 fee = amount / 10;
        uint256 net = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += net;
        totalSupply -= fee;
        emit Transfer(from, to, net);
        return true;
    }
}

contract StandardToken {
    string public name = "Standard Reward";
    string public symbol = "SRWD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    event Transfer(address indexed from, address indexed to, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}

contract RewardDistributor {
    address public rewardToken;
    address private _owner;
    uint256 public credited;

    constructor(address rewardToken_, address owner_) {
        rewardToken = rewardToken_;
        _owner = owner_;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function deposit(uint256 amount) external {
        bool pulled = IERC20(rewardToken).transferFrom(msg.sender, address(this), amount);
        require(pulled, "Token transfer failed");
        credited += amount;
    }

    function withdrawReward(uint256 amount) external {
        // @> VULN: high-level transfer requires a bool. Empty returndata reverts this call. A false return fails the require below. Either way the reward balance stays here.
        bool success = IERC20(rewardToken).transfer(owner(), amount);
        require(success, "Token transfer failed");
        // FIX: SafeERC20.safeTransfer(IERC20(rewardToken), owner(), amount);
    }
}

contract Exploit {
    address public constant OWNER = 0x0000000000000000000000000000000000000B0b;
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant FEE_STUCK = 900 ether;

    NoReturnToken public noReturn; // CREATE nonce 1
    RewardDistributor public distStuck; // CREATE nonce 2
    StandardToken public standard; // CREATE nonce 3
    RewardDistributor public distControl; // CREATE nonce 4
    FeeToken public feeToken; // CREATE nonce 5
    RewardDistributor public distFee; // CREATE nonce 6

    uint256 public stuckNoReturn;
    uint256 public ownerNoReturn;
    uint256 public stuckFee;
    uint256 public ownerFee;
    uint256 public paidControl;
    uint256 public leftControl;

    constructor() {
        noReturn = new NoReturnToken();
        distStuck = new RewardDistributor(address(noReturn), OWNER);
        standard = new StandardToken();
        distControl = new RewardDistributor(address(standard), OWNER);
        feeToken = new FeeToken();
        distFee = new RewardDistributor(address(feeToken), OWNER);
    }

    function run() external {
        noReturn.mint(address(this), AMOUNT);
        noReturn.transfer(address(distStuck), AMOUNT);

        try distStuck.withdrawReward(AMOUNT) {
            revert("no-return claim paid");
        } catch {}

        stuckNoReturn = noReturn.balanceOf(address(distStuck));
        ownerNoReturn = noReturn.balanceOf(OWNER);
        require(stuckNoReturn == AMOUNT, "no-return not stuck");
        require(ownerNoReturn == 0, "owner was paid no-return");

        feeToken.mint(address(this), AMOUNT);
        feeToken.approve(address(distFee), AMOUNT);
        distFee.deposit(AMOUNT);
        uint256 feeOwed = distFee.credited();

        try distFee.withdrawReward(feeOwed) {
            revert("fee claim paid");
        } catch {}

        stuckFee = feeToken.balanceOf(address(distFee));
        ownerFee = feeToken.balanceOf(OWNER);
        require(stuckFee == FEE_STUCK, "fee tokens not stuck");
        require(ownerFee == 0, "owner was paid fee token");

        standard.mint(address(this), AMOUNT);
        standard.transfer(address(distControl), AMOUNT);
        distControl.withdrawReward(AMOUNT);

        paidControl = standard.balanceOf(OWNER);
        leftControl = standard.balanceOf(address(distControl));
        require(paidControl == AMOUNT, "control did not pay");
        require(leftControl == 0, "control left a balance");
    }
}
