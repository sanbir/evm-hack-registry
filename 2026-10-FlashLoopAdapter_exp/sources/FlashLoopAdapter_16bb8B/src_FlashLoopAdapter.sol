// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FlashLoopAdapter — atomic open/close of Aave v3 leveraged loops via a Safe module
/// @notice Installed as a Safe MODULE (safe.enableModule(adapter)). The Safe calls open()/close()
///         in ONE transaction; the adapter takes free flash liquidity (Morpho / Balancer v2, or
///         Aave flashLoanSimple as paid fallback), and drives the Safe itself for every
///         position-touching call via execTransactionFromModule — so the POSITION IS OWNED BY THE
///         SAFE, with no credit delegation and no aToken approvals to any external contract.
///
///         open:  flash debt (L-1)*E -> swap debt->collateral (router calldata) -> supply to pool
///                onBehalfOf safe -> [setUserEMode] -> safe borrows debt (module) -> safe transfers
///                debt to adapter (module) -> repay flash -> sweep dust to safe.
///         close: flash debt -> repay pool onBehalfOf safe -> safe withdraws collateral to adapter
///                (module) -> swap collateral->debt (router calldata) -> repay flash -> sweep BOTH
///                tokens to safe.
///
///         Aave-v3-only surface; swap route/calldata is quoted OFF-CHAIN at execution and
///         min-out enforced ON-CHAIN. Stateless between calls (transient pending-op hash).
///
///         Engine contract: ~/goals/aave-yield-hunter/engine/CONTRACTS.md ("Flash liquidity").

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ISafe {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external returns (bool);
    function isModuleEnabled(address module) external view returns (bool);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external returns (uint256);
    function flashLoanSimple(address receiverAddress, address asset, uint256 amount, bytes calldata params,
        uint16 referralCode) external;
}

interface IMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

interface IBalancerV2Vault {
    function flashLoan(address recipient, address[] calldata tokens, uint256[] calldata amounts,
        bytes calldata userData) external;
}

contract FlashLoopAdapter {
    enum Provider { MORPHO, BALANCER_V2, AAVE_SIMPLE }
    enum Op { OPEN, CLOSE }

    struct Params {
        Op op;
        Provider provider;
        address providerAddr;   // Morpho / Balancer vault / Aave pool (flash source)
        address pool;           // Aave v3 Pool of the target market
        address collateral;     // collateral underlying
        address debt;           // debt underlying (== flashed asset)
        uint256 flashAmount;    // debt units to flash: open = (L-1)*E equiv; close = outstanding debt
        address swapRouter;     // aggregator router (quoted off-chain at execution)
        bytes   swapCalldata;   // router call: open = debt->collateral, close = collateral->debt
        uint256 minOut;         // min output of the swap leg, on-chain enforced
        uint8   emodeId;        // 0 = skip setUserEMode
        uint256 withdrawAmount; // close only: collateral to withdraw (type(uint).max = all)
    }

    error NotSafeOwner();
    error ModuleNotEnabled();
    error UntrustedCallback();
    error ModuleExecFailed(string what);
    error SwapMinOut(uint256 got, uint256 want);
    error FlashShortfall(uint256 have, uint256 owe);

    uint256 private constant VARIABLE_RATE = 2;

    // transient pending-operation guard: hash of (safe, params) set right before the
    // flash call, checked+cleared in the callback. tstore -> zero cost between txs.
    bytes32 private transient _pending;
    address private transient _safe;

    // ---------------------------------------------------------------- entrypoints

    /// @notice msg.sender MUST be the Safe (which has this adapter enabled as module).
    function open(Params calldata p) external { _start(p); }
    function close(Params calldata p) external { _start(p); }

    function _start(Params calldata p) internal {
        if (!ISafe(msg.sender).isModuleEnabled(address(this))) revert ModuleNotEnabled();
        _safe = msg.sender;
        _pending = keccak256(abi.encode(msg.sender, p));
        bytes memory data = abi.encode(p);
        if (p.provider == Provider.MORPHO) {
            IMorpho(p.providerAddr).flashLoan(p.debt, p.flashAmount, data);
        } else if (p.provider == Provider.BALANCER_V2) {
            address[] memory tokens = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            tokens[0] = p.debt; amounts[0] = p.flashAmount;
            IBalancerV2Vault(p.providerAddr).flashLoan(address(this), tokens, amounts, data);
        } else {
            IAavePool(p.providerAddr).flashLoanSimple(address(this), p.debt, p.flashAmount, data, 0);
        }
        // sweep every touched token back to the Safe — adapter never holds funds
        _sweep(p.debt);
        _sweep(p.collateral);
    }

    // ---------------------------------------------------------------- flash callbacks

    /// Morpho: onMorphoFlashLoan(uint256 assets, bytes data); repay via approve (Morpho pulls).
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        Params memory p = _validate(data);
        _run(p, assets, 0);
        IERC20(p.debt).approve(msg.sender, assets);
    }

    /// Balancer v2: receiveFlashLoan(tokens, amounts, feeAmounts, userData); repay via transfer.
    function receiveFlashLoan(address[] calldata tokens, uint256[] calldata amounts,
                              uint256[] calldata feeAmounts, bytes calldata userData) external {
        Params memory p = _validate(userData);
        _run(p, amounts[0], feeAmounts[0]);
        IERC20(tokens[0]).transfer(msg.sender, amounts[0] + feeAmounts[0]);
    }

    /// Aave: executeOperation(asset, amount, premium, initiator, params); repay via approve (pool pulls).
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator,
                              bytes calldata params) external returns (bool) {
        if (initiator != address(this)) revert UntrustedCallback();
        Params memory p = _validate(params);
        _run(p, amount, premium);
        IERC20(asset).approve(msg.sender, amount + premium);
        return true;
    }

    // ---------------------------------------------------------------- core

    function _validate(bytes memory data) internal returns (Params memory p) {
        p = abi.decode(data, (Params));
        // provider addr is bound into the pending hash — only the flash source we just
        // called can re-enter, with exactly the params we committed to.
        if (msg.sender != p.providerAddr) revert UntrustedCallback();
        bytes32 h = keccak256(abi.encode(_safe, p));
        if (h != _pending) revert UntrustedCallback();
        _pending = bytes32(0);
    }

    function _run(Params memory p, uint256 flashed, uint256 fee) internal {
        address safe = _safe;
        if (p.op == Op.OPEN) {
            // 1. swap flashed debt -> collateral (router quoted off-chain, min-out on-chain)
            uint256 got = _swap(p.debt, p.collateral, p.swapRouter, p.swapCalldata, p.minOut);
            // 2. supply collateral to the pool, position owned by the Safe
            IERC20(p.collateral).approve(p.pool, got);
            IAavePool(p.pool).supply(p.collateral, got, safe, 0);
            // 3. e-mode BEFORE borrow — the quoted LTV only exists inside the category
            if (p.emodeId != 0) {
                _moduleExec(safe, p.pool, abi.encodeWithSignature("setUserEMode(uint8)", p.emodeId), "setUserEMode");
            }
            // 4. Safe borrows the flash repayment (+fee) against its new collateral
            uint256 owed = flashed + fee;
            _moduleExec(safe, p.pool,
                abi.encodeWithSignature("borrow(address,uint256,uint256,uint16,address)",
                                        p.debt, owed, VARIABLE_RATE, uint16(0), safe), "borrow");
            // 5. Safe funds the flash repayment
            _moduleExec(safe, p.debt,
                abi.encodeWithSignature("transfer(address,uint256)", address(this), owed), "fund repay");
        } else {
            // 1. repay the Safe's debt with the flashed asset
            IERC20(p.debt).approve(p.pool, flashed);
            IAavePool(p.pool).repay(p.debt, flashed, VARIABLE_RATE, safe);
            // 2. Safe withdraws collateral straight to the adapter
            _moduleExec(safe, p.pool,
                abi.encodeWithSignature("withdraw(address,uint256,address)",
                                        p.collateral, p.withdrawAmount, address(this)), "withdraw");
            // 3. swap collateral -> debt to cover the flash (+fee); leftovers sweep to Safe
            _swap(p.collateral, p.debt, p.swapRouter, p.swapCalldata, p.minOut);
            uint256 have = IERC20(p.debt).balanceOf(address(this));
            if (have < flashed + fee) revert FlashShortfall(have, flashed + fee);
        }
    }

    function _swap(address tokenIn, address tokenOut, address router, bytes memory data, uint256 minOut)
        internal returns (uint256 got)
    {
        IERC20(tokenIn).approve(router, type(uint256).max);
        (bool ok, bytes memory ret) = router.call(data);
        if (!ok) {
            assembly { revert(add(ret, 0x20), mload(ret)) }
        }
        IERC20(tokenIn).approve(router, 0);
        got = IERC20(tokenOut).balanceOf(address(this));
        if (got < minOut) revert SwapMinOut(got, minOut);
    }

    function _moduleExec(address safe, address to, bytes memory data, string memory what) internal {
        if (!ISafe(safe).execTransactionFromModule(to, 0, data, 0)) revert ModuleExecFailed(what);
    }

    function _sweep(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) IERC20(token).transfer(_safe, bal);
    }
}
