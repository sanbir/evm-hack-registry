// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Rio Network — H-5 (Sherlock 2024-02, issue 84)
    ValidatorDetails.swapValidatorDetails loads a 48-byte BLS public key with
    mstore(part1) and then mstore(shr(128, part2)) sixteen bytes later.
    The second write zeros bytes 16..31. reportOutOfOrderValidatorExits then
    deposits 32 ETH per validator to a key nobody can withdraw.

    Key from the report:
    0x95cfcb859956953f9834f8b14cdaa939e472a2b5d0471addbe490b97ed99c6eb
      8af94bc3ba4d4bfa93d087d522e4b78d
    After the bug the middle 16 bytes are zero. Two validators lock 64 ETH.
    The control stores part2 before part1 and withdraws all 64 ETH.
*/

contract Eth {
    string public symbol = "ETH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract BeaconDeposit {
    Eth public immutable eth;
    uint256 public locked;
    mapping(bytes32 => uint256) public deposited;

    constructor(Eth _eth) {
        eth = _eth;
    }

    function deposit(bytes calldata pubkey) external {
        require(pubkey.length == 48, "len");
        require(eth.transferFrom(msg.sender, address(this), 32 ether), "pull");
        deposited[keccak256(pubkey)] += 32 ether;
        locked += 32 ether;
    }

    function withdraw(bytes calldata pubkey) external returns (uint256 amount) {
        amount = deposited[keccak256(pubkey)];
        if (amount == 0) {
            return 0;
        }
        deposited[keccak256(pubkey)] = 0;
        locked -= amount;
        require(eth.transfer(msg.sender, amount), "pay");
    }
}

contract ValidatorDetails {
    mapping(uint256 => mapping(uint256 => bytes32[2])) internal keys;
    bytes public corruptedKey1;
    bytes public corruptedKey2;

    function computeStorageKeyOffset(uint256 operatorId, uint256 index) public pure returns (uint256 slot) {
        uint256 opSlot = uint256(keccak256(abi.encode(operatorId, uint256(0))));
        slot = uint256(keccak256(abi.encode(index, opSlot)));
    }

    function storeKey(uint256 operatorId, uint256 index, bytes32 part1, bytes32 part2) external {
        uint256 slot = computeStorageKeyOffset(operatorId, index);
        assembly {
            sstore(slot, part1)
            sstore(add(slot, 1), part2)
        }
    }

    function swapValidatorDetails(uint256 operatorId, uint256 startIndex1, uint256 startIndex2) external {
        bytes memory key1 = new bytes(48);
        bytes memory key2 = new bytes(48);
        uint256 keyOffset1 = computeStorageKeyOffset(operatorId, startIndex1);
        uint256 keyOffset2 = computeStorageKeyOffset(operatorId, startIndex2);
        bool isEmpty;
        bytes32 part1a;
        bytes32 part2a;
        bytes32 part1b;
        bytes32 part2b;
        assembly {
            part1a := sload(keyOffset1)
            part2a := sload(add(keyOffset1, 1))
            part1b := sload(keyOffset2)
            part2b := sload(add(keyOffset2, 1))
            isEmpty := or(iszero(or(part1a, part2a)), iszero(or(part1b, part2b)))
        }
        require(!isEmpty, "empty");
        assembly {
            mstore(add(key1, 0x20), part1a) // Store bytes 0..31
        }
        // @> VULN: shr(128, _part2) is written 16 bytes into part1, so bytes 16..31 of the 48-byte BLS key become zero
        assembly {
            mstore(add(key1, 0x30), shr(128, part2a)) // Store bytes 16..47
        }
        assembly {
            mstore(add(key2, 0x20), part1b) // Store bytes 0..31
            mstore(add(key2, 0x30), shr(128, part2b)) // Store bytes 16..47
        }
        corruptedKey1 = key1;
        corruptedKey2 = key2;
    }
}

contract ValidatorDetailsFixed {
    mapping(uint256 => mapping(uint256 => bytes32[2])) internal keys;
    bytes public loadedKey1;
    bytes public loadedKey2;

    function computeStorageKeyOffset(uint256 operatorId, uint256 index) public pure returns (uint256 slot) {
        uint256 opSlot = uint256(keccak256(abi.encode(operatorId, uint256(0))));
        slot = uint256(keccak256(abi.encode(index, opSlot)));
    }

    function storeKey(uint256 operatorId, uint256 index, bytes32 part1, bytes32 part2) external {
        uint256 slot = computeStorageKeyOffset(operatorId, index);
        assembly {
            sstore(slot, part1)
            sstore(add(slot, 1), part2)
        }
    }

    function swapValidatorDetails(uint256 operatorId, uint256 startIndex1, uint256 startIndex2) external {
        bytes memory key1 = new bytes(48);
        bytes memory key2 = new bytes(48);
        uint256 keyOffset1 = computeStorageKeyOffset(operatorId, startIndex1);
        uint256 keyOffset2 = computeStorageKeyOffset(operatorId, startIndex2);
        assembly {
            let _part1 := sload(keyOffset1)
            let _part2 := sload(add(keyOffset1, 1))
            // FIX: store the shifted tail first so part1 overwrites the zero padding
            mstore(add(key1, 0x30), shr(128, _part2))
            mstore(add(key1, 0x20), _part1)
            _part1 := sload(keyOffset2)
            _part2 := sload(add(keyOffset2, 1))
            mstore(add(key2, 0x30), shr(128, _part2))
            mstore(add(key2, 0x20), _part1)
        }
        loadedKey1 = key1;
        loadedKey2 = key2;
    }
}

contract Exploit {
    bytes32 public constant PART1 = 0x95cfcb859956953f9834f8b14cdaa939e472a2b5d0471addbe490b97ed99c6eb;
    bytes32 public constant PART2 = bytes32(bytes16(0x8af94bc3ba4d4bfa93d087d522e4b78d));
    bytes32 public constant PART1B = 0xaabbccddeeff00112233445566778899aabbccddeeff00112233445566778899;
    bytes32 public constant PART2B = bytes32(bytes16(0x0123456789abcdeffedcba9876543210));

    Eth public eth;
    ValidatorDetails public details;
    BeaconDeposit public beacon;
    uint256 public withdrawn;
    bool public middleZero;
    bool public keysDiffer;

    constructor() {
        eth = new Eth();
        details = new ValidatorDetails();
        beacon = new BeaconDeposit(eth);
    }

    function run() external {
        details.storeKey(1, 0, PART1, PART2);
        details.storeKey(1, 1, PART1B, PART2B);
        details.swapValidatorDetails(1, 0, 1);

        bytes memory broken = details.corruptedKey1();
        bytes memory intact = _fixedPack(PART1, PART2);
        middleZero = _middleIsZero(broken);
        keysDiffer = keccak256(broken) != keccak256(intact);
        require(middleZero, "middle");
        require(keysDiffer, "same key");
        require(keccak256(broken) == keccak256(_buggyPack(PART1, PART2)), "pack");

        eth.mint(address(this), 64 ether);
        eth.approve(address(beacon), 64 ether);
        beacon.deposit(details.corruptedKey1());
        uint256 afterFirstDeposit = beacon.locked();
        beacon.deposit(details.corruptedKey2());
        uint256 afterSecondDeposit = beacon.locked();
        withdrawn = beacon.withdraw(intact);
        require(afterFirstDeposit == 32 ether, "first");
        require(afterSecondDeposit == 64 ether, "second");
        require(withdrawn == 0, "withdrew");
        require(beacon.locked() == 64 ether, "locked");
        require(eth.balanceOf(address(beacon)) == 64 ether, "balance");
    }

    function _middleIsZero(bytes memory key) internal pure returns (bool) {
        for (uint256 i = 16; i < 32; ++i) {
            if (key[i] != 0) return false;
        }
        return key.length == 48;
    }

    function _buggyPack(bytes32 part1, bytes32 part2) internal pure returns (bytes memory key) {
        key = new bytes(48);
        assembly {
            mstore(add(key, 0x20), part1)
            mstore(add(key, 0x30), shr(128, part2))
        }
    }

    function _fixedPack(bytes32 part1, bytes32 part2) internal pure returns (bytes memory key) {
        key = new bytes(48);
        assembly {
            mstore(add(key, 0x30), shr(128, part2))
            mstore(add(key, 0x20), part1)
        }
    }
}
