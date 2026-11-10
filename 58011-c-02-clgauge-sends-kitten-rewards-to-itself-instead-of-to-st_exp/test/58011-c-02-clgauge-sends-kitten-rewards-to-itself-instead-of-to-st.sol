// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  KittenSwap CLGauge — KITTEN rewards are sent to the gauge, not the staker
    (Pashov Audit Group, C-02, 7 May 2025, finding 58011).
    SYNTHETIC, cheatcode-free. One transaction, no warp.
    Staking transfers the NFP to the gauge. _getReward then pays
    nfp.ownerOf(tokenId), which is the gauge itself.
    The staker's claim is 0. The gauge still holds N = 1000 KITTEN.
    The fixed claim takes the staker address and pays that address, so the
    staker receives N and the gauge is left with 0. */

contract Kitten {
    string public constant name = "Kitten";
    string public constant symbol = "KITTEN";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract NFP {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "from");
        ownerOf[id] = to;
    }

    function positions(uint256)
        external
        pure
        returns (
            uint96,
            address,
            address,
            address,
            uint24,
            int24 tickLower,
            int24 tickUpper,
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        tickLower = -120;
        tickUpper = 120;
    }
}

contract CLGauge {
    event ClaimRewards(address indexed owner, uint256 reward);

    NFP public nfp;
    Kitten public kitten;
    mapping(uint256 => uint256) public rewards;
    mapping(uint256 => address) public stakerOf;
    int24 public seenLower;
    address public lastPaidTo;

    constructor(NFP nfp_, Kitten kitten_) {
        nfp = nfp_;
        kitten = kitten_;
    }

    function stake(uint256 nfpTokenId) external {
        stakerOf[nfpTokenId] = msg.sender;
        nfp.transferFrom(msg.sender, address(this), nfpTokenId);
    }

    function notifyReward(uint256 nfpTokenId, uint256 amount) external {
        rewards[nfpTokenId] = amount;
    }

    function getReward(uint256 nfpTokenId) external {
        _getReward(nfpTokenId);
    }

    function _updateRewardForNfp(uint256, int24 tickLower, int24) internal {
        seenLower = tickLower;
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        Kitten(token).approve(spender, amount);
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        Kitten(token).transferFrom(from, to, amount);
    }

    function _getReward(uint256 nfpTokenId) internal {
        (, , , , , int24 _tickLower, int24 _tickUpper, , , , , ) = nfp
            .positions(nfpTokenId);

        _updateRewardForNfp(nfpTokenId, _tickLower, _tickUpper);

        uint256 reward = rewards[nfpTokenId];
        // @> VULN: after stake, ownerOf is this gauge, so the staker is not paid
        address owner = nfp.ownerOf(nfpTokenId);
        lastPaidTo = owner;

        if (reward > 0) {
            delete rewards[nfpTokenId];
            _safeApprove(address(kitten), address(this), reward);
            _safeTransferFrom(address(kitten), address(this), owner, reward);
            emit ClaimRewards(owner, reward);
        }
    }
}

contract CLGaugeFixed {
    NFP public nfp;
    Kitten public kitten;
    mapping(uint256 => uint256) public rewards;
    mapping(uint256 => address) public stakerOf;

    constructor(NFP nfp_, Kitten kitten_) {
        nfp = nfp_;
        kitten = kitten_;
    }

    function stake(uint256 nfpTokenId) external {
        stakerOf[nfpTokenId] = msg.sender;
        nfp.transferFrom(msg.sender, address(this), nfpTokenId);
    }

    function notifyReward(uint256 nfpTokenId, uint256 amount) external {
        rewards[nfpTokenId] = amount;
    }

    function getReward(uint256 nfpTokenId) external {
        address staker = stakerOf[nfpTokenId];
        uint256 reward = rewards[nfpTokenId];
        if (reward > 0) {
            delete rewards[nfpTokenId];
            kitten.transfer(staker, reward);
        }
    }
}

contract Exploit {
    uint256 public constant TOKEN_ID = 1;
    uint256 public constant N = 1000 ether;

    Kitten public kitten; // nonce 1
    NFP public nfp; // nonce 2
    CLGauge public gauge; // nonce 3

    uint256 public stakerPaid;
    uint256 public gaugeHeld;

    constructor() {
        kitten = new Kitten();
        nfp = new NFP();
        gauge = new CLGauge(nfp, kitten);
    }

    function run() external {
        nfp.mint(address(this), TOKEN_ID);
        gauge.stake(TOKEN_ID);
        kitten.mint(address(gauge), N);
        gauge.notifyReward(TOKEN_ID, N);

        address nftOwner = nfp.ownerOf(TOKEN_ID);
        gauge.getReward(TOKEN_ID);

        stakerPaid = kitten.balanceOf(address(this));
        gaugeHeld = kitten.balanceOf(address(gauge));

        require(nftOwner == address(gauge), "nft not on the gauge");
        require(gauge.lastPaidTo() == address(gauge), "payee was not the gauge");
        require(stakerPaid == 0, "staker was paid");
        require(gaugeHeld == N, "gauge does not hold N");
        require(kitten.balanceOf(address(gauge)) == N, "balance");
    }
}
