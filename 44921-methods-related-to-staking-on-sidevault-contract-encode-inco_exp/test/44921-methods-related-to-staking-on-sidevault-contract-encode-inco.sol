// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tradable SideVault — staking messages encode marginAccountDeposit, which
    the staking vault does not implement (Zokyo, September 2023).

    The relay reverts. 100 tokens stay in the side vault and the staking
    vault credits 0. The control encodes stakingAccountDeposit. The staking
    vault then holds 100 and the user is credited 100.

    run() does not warp. */

struct TokenInfo {
    address token;
    uint8 decimals;
    bool allowed;
}

contract StakeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StakingVault {
    StakeToken public token;
    address public side;
    mapping(address => uint256) public staked;

    constructor(StakeToken token_) {
        token = token_;
    }

    function setSide(address side_) external {
        require(side == address(0), "side");
        side = side_;
    }

    function stakingAccountDeposit(address user, TokenInfo calldata info, uint256 amount) external {
        info;
        token.transferFrom(side, address(this), amount);
        staked[user] += amount;
    }
}

contract Messenger {
    function relay(bytes calldata payload) external {
        (, address destination, bytes memory inner) = abi.decode(payload, (string, address, bytes));
        (bool ok,) = destination.call(inner);
        require(ok, "relay");
    }
}

contract SideVault {
    StakeToken public token;
    address public dstBaseStakingVault;
    Messenger public messenger;

    constructor(StakeToken token_, address staking_, Messenger messenger_) {
        token = token_;
        dstBaseStakingVault = staking_;
        messenger = messenger_;
    }

    function getAcceptedTokenInfo(address token_) public pure returns (TokenInfo memory) {
        return TokenInfo(token_, 18, true);
    }

    function stakingAccountDeposit(uint256 amount) external virtual returns (bool ok) {
        token.transferFrom(msg.sender, address(this), amount);
        bytes memory payload = abi.encode(
            "md",
            dstBaseStakingVault,
            // @> VULN: marginAccountDeposit is not implemented on the staking vault
            abi.encodeWithSignature(
                "marginAccountDeposit(address,(address,uint8,bool),uint256)",
                msg.sender,
                getAcceptedTokenInfo(address(token)),
                amount
            )
        );
        (ok,) = address(messenger).call(abi.encodeCall(Messenger.relay, (payload)));
    }
}

contract SideVaultFixed is SideVault {
    constructor(StakeToken token_, address staking_, Messenger messenger_) SideVault(token_, staking_, messenger_) {}

    function stakingAccountDeposit(uint256 amount) external override returns (bool ok) {
        token.transferFrom(msg.sender, address(this), amount);
        token.approve(dstBaseStakingVault, amount);
        bytes memory payload = abi.encode(
            "md",
            dstBaseStakingVault,
            abi.encodeWithSignature(
                "stakingAccountDeposit(address,(address,uint8,bool),uint256)",
                msg.sender,
                getAcceptedTokenInfo(address(token)),
                amount
            )
        );
        (ok,) = address(messenger).call(abi.encodeCall(Messenger.relay, (payload)));
        require(ok, "stake");
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 100 ether;

    StakeToken public token;
    StakingVault public staking;
    Messenger public messenger;
    SideVault public side;
    bool public relayed;
    uint256 public stayed;
    uint256 public credited;

    constructor() {
        token = new StakeToken();
        staking = new StakingVault(token);
        messenger = new Messenger();
        side = new SideVault(token, address(staking), messenger);
        staking.setSide(address(side));
        token.mint(address(this), AMOUNT);
    }

    function run() external {
        token.approve(address(side), AMOUNT);
        relayed = side.stakingAccountDeposit(AMOUNT);
        stayed = token.balanceOf(address(side));
        credited = staking.staked(address(this));
        require(relayed == false, "relayed");
        require(stayed == AMOUNT, "stayed");
        require(credited == 0, "credited");
    }
}
