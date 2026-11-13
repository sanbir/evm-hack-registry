// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Kinto — resetSigners leaves signerPolicy at 2 with one owner
    (MixBytes, finding 30497). Not the deployContract front-run.
    A wallet on policy 2 (n-1) is reset to a single owner. Policy stays 2.
    _validateSignature then takes the three-signature branch and reverts,
    so the 1000 held by the wallet cannot move. The control sets policy
    back to 1 and the same call pays the 1000. */

contract Asset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Wallet {
    uint8 public constant SINGLE_SIGNER = 1;
    uint8 public constant MINUS_ONE_SIGNER = 2;
    address[] public owners;
    uint8 public signerPolicy = 1;
    Asset public token;
    address public owner0;
    uint256 public stepOwners;

    constructor(Asset token_, address owner0_) {
        token = token_;
        owner0 = owner0_;
        owners.push(owner0_);
    }

    function getOwnersCount() external view returns (uint256) {
        return owners.length;
    }

    function setSignerPolicy(uint8 policy) external {
        require(msg.sender == address(this), "only self");
        require(policy > 0 && policy < 4 && policy != signerPolicy, "policy");
        require(policy == 1 || owners.length > 1, "owners");
        signerPolicy = policy;
    }

    function resetSigners(address[] calldata newSigners) external {
        require(msg.sender == address(this), "only self");
        _resetSigners(newSigners);
    }

    function _resetSigners(address[] calldata newSigners) internal {
        require(newSigners.length > 0 && newSigners.length <= 3, "len");
        require(newSigners[0] == owner0, "first");
        owners = newSigners;
        // @> VULN: signerPolicy is left unchanged when the owner set shrinks
        stepOwners = owners.length;
    }

    function resetSignersFixed(address[] calldata newSigners) external {
        require(msg.sender == address(this), "only self");
        require(newSigners.length > 0 && newSigners.length <= 3, "len");
        owners = newSigners;
        if (newSigners.length == 1) signerPolicy = SINGLE_SIGNER;
    }

    function shrinkToOne() external {
        address[] memory one = new address[](1);
        one[0] = owner0;
        this.resetSigners(one);
    }

    function shrinkToOneFixed() external {
        address[] memory one = new address[](1);
        one[0] = owner0;
        this.resetSignersFixed(one);
    }

    function seedTwo(address second) external {
        require(msg.sender == address(this), "only self");
        address[] memory two = new address[](2);
        two[0] = owner0;
        two[1] = second;
        owners = two;
    }

    function armPolicyTwo(address second) external {
        this.seedTwo(second);
        this.setSignerPolicy(MINUS_ONE_SIGNER);
    }

    function execute(uint256 amount, bytes calldata signature) external {
        uint256 bad = _validateSignature(signature);
        require(bad == 0, "sig");
        require(token.transfer(owners[0], amount), "pay");
    }

    function _validateSignature(bytes calldata signature) internal view returns (uint256) {
        if (signature.length != 65 * owners.length) return 1;
        bytes32 hash;
        if (signerPolicy == 1) {
            if (owners[0] != _recover(hash, signature)) return 1;
            return 0;
        }
        uint256 requiredSigners = signerPolicy == 3 ? owners.length : owners.length - 1;
        if (owners.length == 2) {
            requiredSigners = _checkTwo(hash, signature, requiredSigners);
        } else {
            (bytes memory s0, bytes memory s1, bytes memory s2) = _extractThree(signature);
            if (owners.length > 0 && owners[0] == _recover(hash, s0)) requiredSigners -= 1;
            if (owners.length > 1 && owners[1] == _recover(hash, s1)) requiredSigners -= 1;
            if (owners.length > 2 && owners[2] == _recover(hash, s2)) requiredSigners -= 1;
        }
        return requiredSigners;
    }

    function _extractThree(bytes calldata signature)
        internal
        pure
        returns (bytes memory, bytes memory, bytes memory)
    {
        require(signature.length == 195, "three sigs");
        return (signature[0:65], signature[65:130], signature[130:195]);
    }

    function _checkTwo(bytes32 hash, bytes calldata signature, uint256 requiredSigners) internal view returns (uint256) {
        if (owners[0] == _recover(hash, signature[0:65])) requiredSigners -= 1;
        if (owners[1] == _recover(hash, signature[65:130])) requiredSigners -= 1;
        return requiredSigners;
    }

    function _recover(bytes32, bytes memory sig) internal pure returns (address a) {
        assembly {
            a := shr(96, mload(add(sig, 32)))
        }
    }
}

contract Exploit {
    uint256 public constant N = 1_000 ether;
    address public constant BOB = address(0xB0B);

    Asset public token;
    Wallet public wallet;
    bool public moved;
    uint256 public stuck;
    uint8 public policyAfter;
    uint256 public ownersAfter;
    bool public controlMoved;
    uint256 public controlBalance;

    constructor() {
        token = new Asset();
        wallet = new Wallet(token, address(this));
    }

    function oneSig() public view returns (bytes memory) {
        return abi.encodePacked(address(this), bytes32(0), bytes13(0));
    }

    function run() external {
        wallet.armPolicyTwo(BOB);
        wallet.shrinkToOne();
        policyAfter = wallet.signerPolicy();
        ownersAfter = wallet.getOwnersCount();
        token.mint(address(wallet), N);
        (moved,) = address(wallet).call(abi.encodeWithSignature("execute(uint256,bytes)", N, oneSig()));
        stuck = token.balanceOf(address(wallet));
        require(policyAfter == 2, "policy");
        require(ownersAfter == 1, "owners");
        require(moved == false, "moved");
        require(stuck == N, "stuck");
    }

    function runControl() external {
        wallet.armPolicyTwo(BOB);
        wallet.shrinkToOneFixed();
        require(wallet.signerPolicy() == 1, "policy");
        token.mint(address(wallet), N);
        (controlMoved,) = address(wallet).call(abi.encodeWithSignature("execute(uint256,bytes)", N, oneSig()));
        controlBalance = token.balanceOf(address(this));
        require(controlMoved == true, "moved");
        require(controlBalance == N, "paid");
        require(token.balanceOf(address(wallet)) == 0, "empty");
    }
}
