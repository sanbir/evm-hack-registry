// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {
    Exploit,
    HonestBuyer,
    HonestCurve,
    IPSeed,
    IIPSeedCurve,
    MaliciousCurve
} from "./31586-c-02-attacker-can-drain-all-eth-from-ipseed-due-to-malicious.sol";

/// Warden's fix: spawn accepts only a whitelisted curve.
contract IPSeedFixed {
    error InvalidTokenId();
    error TokenAlreadyExists();
    error UntrustedCurve();

    IIPSeedCurve public trusted;

    struct Metadata {
        address sourcer;
        address beneficiary;
        string name;
        string symbol;
        string projectId;
        IIPSeedCurve priceCurve;
        bytes32 curveParameters;
    }

    mapping(uint256 => Metadata) public tokenMeta;
    mapping(uint256 => mapping(address => uint256)) public balanceOf;
    mapping(uint256 => uint256) public totalSupply;

    constructor(IIPSeedCurve _trusted) {
        trusted = _trusted;
    }

    function computeTokenId(address sourcer, string memory projectId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(sourcer, projectId)));
    }

    function spawn(
        uint256 tokenId,
        string calldata name,
        string calldata symbol,
        string calldata projectId,
        IIPSeedCurve curve,
        bytes32 curveParameters,
        address sourcer
    ) public {
        if (address(curve) != address(trusted)) revert UntrustedCurve();
        if (tokenId != computeTokenId(msg.sender, projectId)) revert InvalidTokenId();
        if (bytes(tokenMeta[tokenId].projectId).length > 0) revert TokenAlreadyExists();
        tokenMeta[tokenId] =
            Metadata(sourcer, sourcer, name, symbol, projectId, curve, curveParameters);
    }

    function getBuyPrice(uint256 tokenId, uint256 want) public view returns (uint256 gross) {
        gross = tokenMeta[tokenId].priceCurve.getBuyPrice(totalSupply[tokenId], want, tokenMeta[tokenId].curveParameters);
    }

    function getSellPrice(uint256 tokenId, uint256 sell) public view returns (uint256 net) {
        net = tokenMeta[tokenId].priceCurve.getSellPrice(totalSupply[tokenId], sell, tokenMeta[tokenId].curveParameters);
    }

    function mint(uint256 tokenId, uint256 amount) external payable {
        uint256 gross = getBuyPrice(tokenId, amount);
        require(msg.value >= gross, "underpaid");
        balanceOf[tokenId][msg.sender] += amount;
        totalSupply[tokenId] += amount;
    }

    function burn(address account, uint256 tokenId, uint256 amount) public {
        require(account == msg.sender, "not holder");
        uint256 net = getSellPrice(tokenId, amount);
        balanceOf[tokenId][account] -= amount;
        totalSupply[tokenId] -= amount;
        (bool ok,) = account.call{value: net}("");
        require(ok, "eth transfer failed");
    }

    receive() external payable {}
}

contract FixedBuyer {
    IPSeedFixed public ipSeed;
    HonestCurve public curve;
    uint256 public tokenId;

    constructor(IPSeedFixed _ipSeed, HonestCurve _curve) {
        ipSeed = _ipSeed;
        curve = _curve;
    }

    function buy() external {
        tokenId = ipSeed.computeTokenId(address(this), "lab-1");
        ipSeed.spawn(tokenId, "Lab", "LAB", "lab-1", curve, bytes32(0), address(this));
        ipSeed.mint{value: 10 ether}(tokenId, 1);
    }

    function exit() external {
        ipSeed.burn(address(this), tokenId, 1);
    }

    receive() external payable {}
}

contract Finding31586Test is Test {
    function test_exploit_malicious_curve_drains_pool() public {
        Exploit e = new Exploit();
        vm.deal(address(e.buyer()), 10 ether);
        uint256 attackerBefore = address(e).balance;

        e.run();

        assertEq(address(e).balance - attackerBefore, 10 ether, "attacker took the 10 ETH deposit");
        assertEq(address(e.ipSeed()).balance, 0, "IPSeed is empty");
        assertEq(address(e.buyer()).balance, 0, "buyer was not refunded");
        assertEq(e.ipSeed().balanceOf(e.buyer().tokenId(), address(e.buyer())), 1, "buyer still holds the token");
        assertFalse(e.victimExitOk(), "victim exit must fail");
    }

    function test_control_whitelist_blocks_the_curve_and_refunds_the_buyer() public {
        HonestCurve honest = new HonestCurve();
        MaliciousCurve evil = new MaliciousCurve();
        IPSeedFixed fixedSeed = new IPSeedFixed(honest);
        FixedBuyer buyer = new FixedBuyer(fixedSeed, honest);
        vm.deal(address(buyer), 10 ether);
        uint256 attackerBefore = address(this).balance;

        buyer.buy();
        assertEq(address(fixedSeed).balance, 10 ether, "honest buy escrowed 10 ETH");

        uint256 evilId = fixedSeed.computeTokenId(address(this), "evil");
        vm.expectRevert(IPSeedFixed.UntrustedCurve.selector);
        fixedSeed.spawn(evilId, "Evil", "EVIL", "evil", evil, bytes32(0), address(this));

        buyer.exit();
        assertEq(address(buyer).balance, 10 ether, "buyer was refunded");
        assertEq(address(fixedSeed).balance, 0, "nothing left in the pool");
        assertEq(address(this).balance, attackerBefore, "attacker received nothing");
    }
}
