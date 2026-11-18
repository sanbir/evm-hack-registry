// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  StationX — cross-chain DAO fees are addressed to the LayerZero deployer
    (Pashov, finding 41382).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: createCrossChainERC20DAO stores msg.sender as ownerAddress, and the
    only caller allowed is the LayerZero deployer. The buy path sends ownerShare to
    that address. The deployer has no receive(), the call result is ignored, and the
    DAO owner is paid 0. Vulnerable lines preserved verbatim below (@> VULN). */

contract DaoOwner {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

contract Treasury {
    receive() external payable {}
}

contract LZDeployer {
    function create(Factory factory, address dao, address intendedOwner) external {
        factory.createCrossChainERC20DAO(dao, intendedOwner);
    }
}

contract Factory {
    struct CrossChainDetails {
        uint256 commLayerId;
        bool isNotified;
        address ownerAddress;
        bool onlyAllowWhitelist;
    }

    address public commLayer;
    address public treasury;
    address public realOwner;
    mapping(address => CrossChainDetails) public ccDetails;

    constructor(address commLayer_, address treasury_) {
        commLayer = commLayer_;
        treasury = treasury_;
    }

    function createCrossChainERC20DAO(address _daoAddress, address intendedOwner) external {
        require(msg.sender == commLayer, "Caller not LZ Deployer");
        realOwner = intendedOwner;
        address lzOwner = msg.sender; // @> VULN: ownerAddress is the LayerZero deployer, not the DAO creator
        // FIX: address lzOwner = intendedOwner;
        ccDetails[_daoAddress] = CrossChainDetails(1, false, lzOwner, false);
    }

    function buy(address _daoAddress) external payable {
        uint256 ownerShare = msg.value / 10;
        address feeTo = ccDetails[_daoAddress].ownerAddress; // @> VULN: owner fee is sent to the stored LayerZero deployer
        if (feeTo == address(0)) feeTo = realOwner;
        (bool ok,) = payable(feeTo).call{value: ownerShare}("");
        ok;
        (bool okRest,) = payable(treasury).call{value: msg.value - ownerShare}("");
        require(okRest, "treasury");
    }

    function ownerOf(address dao) external view returns (address) {
        return ccDetails[dao].ownerAddress;
    }
}

contract Exploit {
    DaoOwner public daoOwner; // nonce 1
    Treasury public treasury; // nonce 2
    LZDeployer public lz; // nonce 3
    Factory public factory; // nonce 4
    address public dao;
    uint256 public ownerReceived;
    uint256 public stuck;

    constructor() {
        daoOwner = new DaoOwner();
        treasury = new Treasury();
        lz = new LZDeployer();
        factory = new Factory(address(lz), address(treasury));
        dao = address(0xDA0);
    }

    function run() external payable {
        lz.create(factory, dao, address(daoOwner));
        factory.buy{value: msg.value}(dao);
        ownerReceived = daoOwner.received();
        stuck = address(factory).balance;
        require(factory.ownerOf(dao) == address(lz), "owner is not the deployer");
        require(ownerReceived == 0, "dao owner was paid");
        require(stuck == msg.value / 10, "owner share was not stuck");
        require(address(treasury).balance == msg.value - msg.value / 10, "raise not booked");
    }
}
