// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

contract Binding is Ownable {
    error Bound();
    error CodeError();
    error ParentError();
    error GenCodeError();

    event Bind(
        address indexed account,
        address indexed parent,
        bytes8 currCode,
        bytes8 parentCode
    );

    mapping(address => bytes8) public accountCode;
    mapping(bytes8 => address) public codeAccount;
    mapping(address => address) public parents;
    address public root;

    bytes private constant chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";

    constructor(address genesis, address m) Ownable(m) {
        bytes8 code = "LPD88888";
        accountCode[genesis] = code;
        codeAccount[code] = genesis;
        parents[genesis] = address(1);
        root = genesis;
        emit Bind(genesis, address(1), code, "");
    }

    function bind(bytes8 code) external {
        if (parents[msg.sender] != address(0)) {
            revert Bound();
        }
        address parent = codeAccount[code];
        if (parent == address(0)) {
            revert CodeError();
        }
        if (parents[parent] == address(0)) {
            revert ParentError();
        }
        uint256 seed = uint256(keccak256(abi.encodePacked(msg.sender, code)));
        bytes8 currCode = generateCode(seed);
        uint256 i = 4;
        while (i > 0 && codeAccount[currCode] != address(0)) {
            ++seed;
            currCode = generateCode(seed);
            --i;
        }
        if (codeAccount[currCode] != address(0)) {
            revert GenCodeError();
        }
        accountCode[msg.sender] = currCode;
        codeAccount[currCode] = msg.sender;
        parents[msg.sender] = parent;
        emit Bind(msg.sender, parent, currCode, code);
    }

    function generateCode(uint256 seed) public view returns (bytes8) {
        bytes memory code = new bytes(8);
        for (uint256 i = 0; i < 8; i++) {
            uint256 rand = uint256(
                keccak256(
                    abi.encodePacked(
                        block.timestamp,
                        blockhash(block.number - 1),
                        seed,
                        i
                    )
                )
            );
            code[i] = chars[rand % chars.length];
        }
        return bytes8(code);
    }
}
