// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Remora Pledge — DividendManager.payoutBalance casts the sum to uint64
    (Cyfrin, 2025-07-04).
    Four settled payouts of 50e6 fit in a uint64. The fifth is 50e18 because
    the payment token was switched to 18 decimals. 50e18 is above uint64 max,
    SafeCast.toUint64 reverts, and the earlier 200 USDC cannot be claimed either. */

library SafeCast {
    error Overflow();

    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert Overflow();
        return uint64(value);
    }
}

contract Stable {
    string public symbol = "USDS";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DividendManager {
    struct PayoutInfo {
        uint256 amount;
        uint256 totalSupply;
    }

    struct Entry {
        uint256 tokenBalance;
    }

    struct Status {
        uint64 calculatedPayout;
    }

    Stable public token;
    mapping(uint16 => PayoutInfo) public payouts;
    mapping(address => Entry) public entries;
    mapping(address => Status) public holderStatus;
    mapping(address => address) public payoutForward;
    uint16 public payRangeStart;
    uint16 public payRangeEnd;
    bool public claimed;

    constructor(Stable _token) {
        token = _token;
    }

    function configure(address holder) external {
        uint256 supply = 1 ether;
        entries[holder] = Entry(supply);
        for (uint16 i = 0; i < 4; i++) {
            payouts[i] = PayoutInfo(50e6, supply);
        }
        payouts[4] = PayoutInfo(50 ether, supply);
        payRangeStart = 4;
        payRangeEnd = 0;
    }

    function pot() public pure returns (uint256) {
        return 4 * 50e6 + 50 ether;
    }

    function payoutBalance(address holder) public returns (uint256 payoutAmount) {
        Entry memory curEntry = entries[holder];
        for (uint16 i = payRangeStart; i >= payRangeEnd; --i) {
            PayoutInfo memory pInfo = payouts[i];
            payoutAmount += (curEntry.tokenBalance * pInfo.amount) / pInfo.totalSupply;
            if (i == 0) break;
        }
        address payoutForwardAddr = payoutForward[holder];
        if (payoutForwardAddr == address(0)) {
            // @> VULN: 50e18 plus the earlier payouts does not fit in uint64, so every unpaid distribution reverts
            holderStatus[holder].calculatedPayout += SafeCast.toUint64(payoutAmount);
        } else {
            holderStatus[payoutForwardAddr].calculatedPayout += SafeCast.toUint64(payoutAmount);
        }
    }

    function claim(address holder) external returns (uint256 amount) {
        amount = payoutBalance(holder);
        claimed = true;
        require(token.transfer(holder, amount), "pay");
    }
}

contract DividendManagerFixed {
    Stable public token;
    uint256 public calculated;

    constructor(Stable _token) {
        token = _token;
    }

    function claim(address holder, uint256 amount) external returns (uint256) {
        calculated = amount;
        require(token.transfer(holder, amount), "pay");
        return amount;
    }
}

contract Exploit {
    Stable public token; // nonce 1
    DividendManager public manager; // nonce 2

    bool public reverted;
    uint256 public stuck;

    constructor() {
        token = new Stable();
        manager = new DividendManager(token);
        manager.configure(address(this));
        token.mint(address(manager), manager.pot());
    }

    function run() external {
        stuck = manager.pot();
        try manager.claim(address(this)) returns (uint256) {
            reverted = false;
        } catch {
            reverted = true;
        }
        require(reverted, "claim reverted");
        require(!manager.claimed(), "nothing paid");
        require(token.balanceOf(address(this)) == 0, "holder received nothing");
        require(token.balanceOf(address(manager)) == stuck, "pot stuck");
        require(stuck > type(uint64).max, "sum exceeds uint64");
        require(4 * 50e6 < type(uint64).max, "earlier payouts would have fit");
    }
}
