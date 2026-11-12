// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Roots Staker — activateBoost(address) does not match BGT's
    activateBoost(address,bytes) (Pashov, February 2025, H-05).
    SYNTHETIC, cheatcode-free. The blamed call is verbatim (@> VULN).

    blockDelta is an integer set in the same transaction. It is not a warp.
    queued boost is 7 reward tokens. The one-argument call reverts, so the
    user receives 0 and the 7 stay in the vault. The two-argument call pays 7. */

contract Reward {
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

interface IWrongBoost {
    function activateBoost(address validator) external;
}

interface IBgt {
    function activateBoost(address user, bytes calldata pubkey) external returns (bool);
}

contract Bgt {
    Reward public token;
    uint256 public constant PAY = 7 ether;

    constructor(Reward _token) {
        token = _token;
    }

    function activateBoost(address user, bytes calldata) external returns (bool) {
        require(token.transfer(user, PAY), "pay");
        return true;
    }
}

contract Staker {
    IWrongBoost public rewardCache;
    address public validator;
    uint256 public queued;
    uint256 public blockDelta;

    constructor(IWrongBoost _bgt, address _validator) {
        rewardCache = _bgt;
        validator = _validator;
    }

    function setBoost(uint256 _queued, uint256 _blockDelta) external {
        queued = _queued;
        blockDelta = _blockDelta;
    }

    function _tryToBoost(address user) internal {
        if (queued > 0 && blockDelta > 8191) {
            // @> VULN: BGT.activateBoost takes (address user, bytes pubkey), not a single address.
            rewardCache.activateBoost(validator);
        }
        user;
    }

    function poke(address user) external {
        _tryToBoost(user);
    }

    function pokeFixed(address user) external {
        if (queued > 0 && blockDelta > 8191) {
            IBgt(address(rewardCache)).activateBoost(user, hex"01");
        }
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 7 ether;

    Reward public token; // nonce 1
    Bgt public bgt; // nonce 2
    Staker public staker; // nonce 3
    bool public boosted;
    uint256 public stuck;
    uint256 public paid;

    constructor() {
        token = new Reward();
        bgt = new Bgt(token);
        staker = new Staker(IWrongBoost(address(bgt)), address(0xBEEF));
    }

    function run() external {
        token.mint(address(bgt), AMOUNT);
        staker.setBoost(AMOUNT, 8192);
        try staker.poke(msg.sender) {
            boosted = true;
        } catch {
            boosted = false;
        }
        stuck = token.balanceOf(address(bgt));
        paid = token.balanceOf(msg.sender);
        require(staker.blockDelta() > 8191, "delta");
        require(boosted == false, "boost should revert");
        require(stuck == AMOUNT, "7 did not stay in the vault");
        require(paid == 0, "user was paid");
    }
}
