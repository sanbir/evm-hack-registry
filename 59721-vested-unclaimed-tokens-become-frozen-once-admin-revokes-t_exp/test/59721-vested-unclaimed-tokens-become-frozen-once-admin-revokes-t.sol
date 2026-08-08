// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/*
    AuditVault finding 59721 — TokenOps / TokenVesting.sol
    "Vested, Unclaimed Tokens Become Frozen Once Admin Revokes the Grant"

    revokeGrant() sets isActive=false and frees ONLY the still-UNVESTED remainder
    from numTokensReservedForVesting. But withdraw() is gated by the
    hasActiveGrant() modifier's `require(isActive, "NO_ACTIVE_GRANT")`, so the
    grantee's ALREADY-VESTED-but-unwithdrawn tokens become permanently frozen:
    they cannot be withdrawn by the grantee and were never freed for reuse.

    Faithful minimal double of the VTVL-style vesting maths. The @> line is the
    guard that blocks a revoked grantee from withdrawing their vested tokens.
*/

// ---------------------------------------------------------------------------
// Minimal ERC20-ish token (faithful minimal double)
// ---------------------------------------------------------------------------
contract MiniToken {
    string public name = "VestToken";
    string public symbol = "VST";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

// ---------------------------------------------------------------------------
// VULNERABLE: TokenVesting (verbatim guard marked with @>)
// ---------------------------------------------------------------------------
contract TokenVesting {
    struct Claim {
        uint40 startTimestamp;
        uint40 endTimestamp;
        uint40 deactivationTimestamp;
        uint256 linearVestAmount;
        uint256 cliffAmount;
        uint256 amountWithdrawn;
        bool isActive;
    }

    MiniToken public token;
    address public admin;
    mapping(address => Claim) public grants;
    uint256 public numTokensReservedForVesting;

    constructor(MiniToken _token) {
        token = _token;
        admin = msg.sender;
    }

    modifier hasActiveGrant(address _recipient) {
        require(grants[_recipient].startTimestamp > 0 || grants[_recipient].cliffAmount > 0, "NO_GRANT");
        require(grants[_recipient].isActive, "NO_ACTIVE_GRANT"); // @> vested-but-unclaimed tokens are frozen once the grant is revoked
        _;
    }

    function createGrant(
        address _recipient,
        uint40 _startTimestamp,
        uint40 _endTimestamp,
        uint256 _linearVestAmount,
        uint256 _cliffAmount
    ) external {
        require(msg.sender == admin, "NOT_ADMIN");
        require(!grants[_recipient].isActive, "GRANT_EXISTS");
        grants[_recipient] = Claim({
            startTimestamp: _startTimestamp,
            endTimestamp: _endTimestamp,
            deactivationTimestamp: 0,
            linearVestAmount: _linearVestAmount,
            cliffAmount: _cliffAmount,
            amountWithdrawn: 0,
            isActive: true
        });
        numTokensReservedForVesting += (_linearVestAmount + _cliffAmount);
    }

    function _baseVestedAmount(Claim memory _claim, uint40 _ref) internal pure returns (uint256) {
        if (_ref >= _claim.endTimestamp) {
            return _claim.linearVestAmount + _claim.cliffAmount;
        }
        if (_ref < _claim.startTimestamp) {
            return 0;
        }
        uint256 linearVested =
            _claim.linearVestAmount * (_ref - _claim.startTimestamp) / (_claim.endTimestamp - _claim.startTimestamp);
        return _claim.cliffAmount + linearVested;
    }

    function claimableAmount(address _recipient) public view returns (uint256) {
        Claim memory c = grants[_recipient];
        uint40 ref = c.isActive ? uint40(block.timestamp) : c.deactivationTimestamp;
        return _baseVestedAmount(c, ref) - c.amountWithdrawn;
    }

    function revokeGrant(address _recipient) external {
        require(msg.sender == admin, "NOT_ADMIN");
        Claim storage c = grants[_recipient];
        require(c.isActive, "NO_ACTIVE_GRANT");
        uint256 finalVested = _baseVestedAmount(c, uint40(block.timestamp));
        uint256 amountRemaining = (c.linearVestAmount + c.cliffAmount) - finalVested;
        c.isActive = false;
        c.deactivationTimestamp = uint40(block.timestamp);
        // only the STILL-UNVESTED remainder is freed; the vested-but-unwithdrawn stays reserved
        numTokensReservedForVesting -= amountRemaining;
    }

    function withdraw() external hasActiveGrant(msg.sender) {
        Claim storage c = grants[msg.sender];
        uint256 amt = claimableAmount(msg.sender);
        c.amountWithdrawn += amt;
        numTokensReservedForVesting -= amt;
        token.transfer(msg.sender, amt);
    }
}

// ---------------------------------------------------------------------------
// FIXED: withdraw() is callable even after revocation (fix option 1)
// ---------------------------------------------------------------------------
contract FixedTokenVesting {
    struct Claim {
        uint40 startTimestamp;
        uint40 endTimestamp;
        uint40 deactivationTimestamp;
        uint256 linearVestAmount;
        uint256 cliffAmount;
        uint256 amountWithdrawn;
        bool isActive;
        bool exists;
    }

    MiniToken public token;
    address public admin;
    mapping(address => Claim) public grants;
    uint256 public numTokensReservedForVesting;

    constructor(MiniToken _token) {
        token = _token;
        admin = msg.sender;
    }

    // FIX: only require the grant to EXIST, not to be active — a revoked grantee
    // must still be able to withdraw the amount already vested at revocation time.
    modifier grantExists(address _recipient) {
        require(grants[_recipient].exists, "NO_GRANT");
        _;
    }

    function createGrant(
        address _recipient,
        uint40 _startTimestamp,
        uint40 _endTimestamp,
        uint256 _linearVestAmount,
        uint256 _cliffAmount
    ) external {
        require(msg.sender == admin, "NOT_ADMIN");
        require(!grants[_recipient].isActive, "GRANT_EXISTS");
        grants[_recipient] = Claim({
            startTimestamp: _startTimestamp,
            endTimestamp: _endTimestamp,
            deactivationTimestamp: 0,
            linearVestAmount: _linearVestAmount,
            cliffAmount: _cliffAmount,
            amountWithdrawn: 0,
            isActive: true,
            exists: true
        });
        numTokensReservedForVesting += (_linearVestAmount + _cliffAmount);
    }

    function _baseVestedAmount(Claim memory _claim, uint40 _ref) internal pure returns (uint256) {
        if (_ref >= _claim.endTimestamp) {
            return _claim.linearVestAmount + _claim.cliffAmount;
        }
        if (_ref < _claim.startTimestamp) {
            return 0;
        }
        uint256 linearVested =
            _claim.linearVestAmount * (_ref - _claim.startTimestamp) / (_claim.endTimestamp - _claim.startTimestamp);
        return _claim.cliffAmount + linearVested;
    }

    function claimableAmount(address _recipient) public view returns (uint256) {
        Claim memory c = grants[_recipient];
        uint40 ref = c.isActive ? uint40(block.timestamp) : c.deactivationTimestamp;
        return _baseVestedAmount(c, ref) - c.amountWithdrawn;
    }

    function revokeGrant(address _recipient) external {
        require(msg.sender == admin, "NOT_ADMIN");
        Claim storage c = grants[_recipient];
        require(c.isActive, "NO_ACTIVE_GRANT");
        uint256 finalVested = _baseVestedAmount(c, uint40(block.timestamp));
        uint256 amountRemaining = (c.linearVestAmount + c.cliffAmount) - finalVested;
        c.isActive = false;
        c.deactivationTimestamp = uint40(block.timestamp);
        numTokensReservedForVesting -= amountRemaining;
    }

    function withdraw() external grantExists(msg.sender) {
        Claim storage c = grants[msg.sender];
        uint256 amt = claimableAmount(msg.sender);
        c.amountWithdrawn += amt;
        numTokensReservedForVesting -= amt;
        token.transfer(msg.sender, amt);
    }
}

// ---------------------------------------------------------------------------
// Grantee helper — represents the end-user calling withdraw()
// ---------------------------------------------------------------------------
contract Grantee {
    function doWithdraw(TokenVesting v) external {
        v.withdraw();
    }
}

// ---------------------------------------------------------------------------
// Exploit: demonstrates the vested tokens become permanently frozen
// ---------------------------------------------------------------------------
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    MiniToken public token;
    TokenVesting public vesting;
    Grantee public grantee;
    MiniToken public marker;

    uint256 public reservedAfterGrant;
    uint256 public claimableBefore;
    uint256 public claimableAfterRevoke;
    uint256 public granteeBalBefore;
    uint256 public granteeBalAfter;
    uint256 public stuckReserved;
    uint256 public frozenVested;
    bool public withdrawReverted;

    function run() external payable {
        // --- unconditional, fixed-order helper creation ---
        token = new MiniToken();
        vesting = new TokenVesting(token);
        grantee = new Grantee();
        marker = new MiniToken();

        // --- preconditions: fund the vesting contract, create a grant ---
        token.mint(address(vesting), 100);

        // start=0, end=2*now => exactly 50% vested at the current block (any timestamp)
        uint40 nowTs = uint40(block.timestamp);
        vesting.createGrant(address(grantee), 0, nowTs * 2, 100, 0);

        reservedAfterGrant = vesting.numTokensReservedForVesting(); // 100
        claimableBefore = vesting.claimableAmount(address(grantee)); // 50

        // --- admin revokes the grant half-way through vesting ---
        vesting.revokeGrant(address(grantee));

        // grantee is still owed the 50 vested tokens...
        claimableAfterRevoke = vesting.claimableAmount(address(grantee)); // 50

        // --- grantee tries to withdraw the vested tokens: BLOCKED by isActive guard ---
        granteeBalBefore = token.balanceOf(address(grantee));
        try grantee.doWithdraw(vesting) {
            withdrawReverted = false;
        } catch {
            withdrawReverted = true;
            // non-fund harm: the vested-but-unwithdrawn amount is frozen forever.
            // Record the frozen magnitude to the SINK via the marker token.
            frozenVested = claimableAfterRevoke; // 50
            marker.mint(SINK, frozenVested);
        }
        granteeBalAfter = token.balanceOf(address(grantee)); // still 0

        // vested tokens remain reserved but are unreachable by everyone
        stuckReserved = vesting.numTokensReservedForVesting(); // 50
    }
}
