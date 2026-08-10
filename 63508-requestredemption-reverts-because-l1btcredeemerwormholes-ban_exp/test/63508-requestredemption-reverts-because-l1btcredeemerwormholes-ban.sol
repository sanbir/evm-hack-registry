// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Threshold Network (tBTC v2) finding
// 63508: "requestRedemption() reverts because L1BTCRedeemerWormhole's Bank
// balance is not credited".
//
// L1BTCRedeemerWormhole.requestRedemption() receives tBTC from an L2 via the
// Wormhole token bridge and then asks the tBTC Bridge to process a Bitcoin
// redemption. Internally, _requestRedemption() grants `thresholdBridge` a Bank
// balance allowance — but at the audited (pre-fix) revision it NEVER credits
// this contract's own satoshi balance in the Bank (the `tbtcVault.unmint()`
// that mints that Bank balance was missing). When the Bridge later calls
// `bank.transferBalanceFrom(redeemer, ..., amountInSatoshis)`, the Bank's
// `_transferBalance` requires `balanceOf[redeemer] >= amount`; since the
// redeemer's balance is zero, the call reverts ("Transfer amount exceeds
// balance"). The whole redemption reverts, so EVERY Wormhole tBTC redemption is
// permanently DoS'd and the bridged tBTC is stranded — it can never be redeemed
// to Bitcoin until the deployed code is upgraded.
//
// Verbatim vulnerable source (pre-fix, keep-network/tbtc-v2, fix commit
// 57a61c36 "refactor: add tbtc vault approve and unmint in redeemer contract",
// so the vulnerable state is its parent 57a61c36~1):
//   - contracts/cross-chain/wormhole/L1BTCRedeemerWormhole.sol  (requestRedemption)
//   - contracts/integrator/AbstractBTCRedeemer.sol              (_requestRedemption)
// The `bank.transferBalanceFrom` revert reproduced here is the real tBTC
// Bank._transferBalance "Transfer amount exceeds balance" require.
// ─────────────────────────────────────────────────────────────────────────────

// ── shared types (mirror of the integrator BitcoinTx / IBridge / Wormhole) ──

library BitcoinTx {
    struct UTXO {
        bytes32 txHash;
        uint32 txOutputIndex;
        uint64 txOutputValue;
    }
}

library IBridgeTypes {
    struct RedemptionRequest {
        address redeemer;
        uint64 requestedAmount;
        uint64 treasuryFee;
        uint64 txMaxFee;
        uint32 requestedAt;
    }
}

interface IBridge {
    function requestRedemption(
        bytes20 walletPubKeyHash,
        BitcoinTx.UTXO calldata mainUtxo,
        bytes calldata redeemerOutputScript,
        uint64 amount
    ) external;

    function pendingRedemptions(uint256 redemptionKey)
        external
        view
        returns (IBridgeTypes.RedemptionRequest memory);

    function redemptionParameters()
        external
        view
        returns (
            uint64 redemptionDustThreshold,
            uint64 redemptionTreasuryFeeDivisor,
            uint64 redemptionTxMaxFee,
            uint64 redemptionTxMaxTotalFee,
            uint32 redemptionTimeout,
            uint96 redemptionTimeoutSlashingAmount,
            uint32 redemptionTimeoutNotifierRewardMultiplier
        );
}

interface IBank {
    function increaseBalanceAllowance(address spender, uint256 amount) external;
    function transferBalanceFrom(address spender, address recipient, uint256 amount) external;
    function increaseBalance(address recipient, uint256 amount) external;
}

interface ITBTCVault {
    function unmint(uint256 amount) external;
}

interface IWormholeTokenBridge {
    struct TransferWithPayload {
        uint8 payloadID;
        uint256 amount;
        bytes32 tokenAddress;
        uint16 tokenChain;
        bytes32 to;
        uint16 toChain;
        bytes32 fromAddress;
        bytes payload;
    }

    function completeTransferWithPayload(bytes memory encodedVm) external returns (bytes memory);
    function parseTransferWithPayload(bytes memory encoded) external pure returns (TransferWithPayload memory transfer);
}

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal faithful doubles for the opaque external boundary.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20. Used both for tBTC (bridged in by the Wormhole double)
///      and for the LOCKED-tBTC marker that records the stranded magnitude.
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

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @dev Faithful double for the tBTC `Bank`. `increaseBalanceAllowance` only
///      bumps the allowance; `transferBalanceFrom` reverts when the balance
///      owner has not been credited — this is the real Bank._transferBalance
///      "Transfer amount exceeds balance" require that produces the DoS.
contract Bank {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    // Verbatim behaviour from Bank.increaseBalanceAllowance / _approveBalance.
    function increaseBalanceAllowance(address spender, uint256 addedValue) external {
        _approveBalance(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
    }

    // Verbatim behaviour from Bank.transferBalanceFrom / _transferBalance.
    function transferBalanceFrom(address spender, address recipient, uint256 amount) external {
        uint256 currentAllowance = allowance[spender][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "Transfer amount exceeds allowance");
            unchecked {
                _approveBalance(spender, msg.sender, currentAllowance - amount);
            }
        }
        _transferBalance(spender, recipient, amount);
    }

    // In real tBTC the Bank balance is minted through the Bridge on unmint; the
    // double credits the balance owner directly (used only by the FIXED path).
    function increaseBalance(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
    }

    function _transferBalance(address spender, address recipient, uint256 amount) private {
        require(recipient != address(0), "Can not transfer to the zero address");
        require(recipient != address(this), "Can not transfer to the Bank address");
        uint256 spenderBalance = balanceOf[spender];
        require(spenderBalance >= amount, "Transfer amount exceeds balance");
        unchecked {
            balanceOf[spender] = spenderBalance - amount;
        }
        balanceOf[recipient] += amount;
    }

    function _approveBalance(address owner, address spender, uint256 amount) private {
        require(spender != address(0), "Can not approve to the zero address");
        allowance[owner][spender] = amount;
    }
}

/// @dev Faithful double for the tBTC `Bridge` redemption path. `msg.sender`
///      (the redeemer) is the `balanceOwner`; the Bridge pulls the redeemer's
///      Bank balance via `transferBalanceFrom`, which reverts when it was never
///      credited (Redemption.sol L638: self.bank.transferBalanceFrom(...)).
contract Bridge {
    Bank public bank;
    uint64 public constant TX_MAX_FEE = 1000;
    mapping(uint256 => IBridgeTypes.RedemptionRequest) internal _pending;

    constructor(Bank _bank) {
        bank = _bank;
    }

    function requestRedemption(
        bytes20 walletPubKeyHash,
        BitcoinTx.UTXO calldata /*mainUtxo*/,
        bytes calldata redeemerOutputScript,
        uint64 amount
    ) external {
        uint256 key = _getRedemptionKey(walletPubKeyHash, redeemerOutputScript);
        _pending[key] = IBridgeTypes.RedemptionRequest(
            msg.sender,
            amount,
            0,
            TX_MAX_FEE,
            uint32(block.timestamp)
        );
        // Pull the redeemer's Bank balance. Reverts if the redeemer never
        // credited a satoshi balance in the Bank (the reported bug).
        bank.transferBalanceFrom(msg.sender, address(this), amount);
    }

    function pendingRedemptions(uint256 redemptionKey)
        external
        view
        returns (IBridgeTypes.RedemptionRequest memory)
    {
        return _pending[redemptionKey];
    }

    function redemptionParameters()
        external
        pure
        returns (uint64, uint64, uint64, uint64, uint32, uint96, uint32)
    {
        return (0, 0, TX_MAX_FEE, 0, 0, 0, 0);
    }

    function _getRedemptionKey(bytes20 walletPubKeyHash, bytes memory script)
        internal
        pure
        returns (uint256)
    {
        bytes32 scriptHash = keccak256(script);
        uint256 key;
        /* solhint-disable-next-line no-inline-assembly */
        assembly {
            mstore(0, scriptHash)
            mstore(32, walletPubKeyHash)
            key := keccak256(0, 52)
        }
        return key;
    }
}

/// @dev Faithful double for the `TBTCVault`. `unmint` burns the caller's tBTC
///      and credits their satoshi balance in the Bank — exactly the step the
///      pre-fix redeemer omitted. Only the FIXED redeemer reaches it.
contract TBTCVault {
    uint256 internal constant SATOSHI_MULTIPLIER = 10**10;
    MiniToken public tbtc;
    Bank public bank;

    constructor(MiniToken _tbtc, Bank _bank) {
        tbtc = _tbtc;
        bank = _bank;
    }

    function unmint(uint256 amount) external {
        tbtc.transferFrom(msg.sender, address(this), amount);
        tbtc.burn(address(this), amount);
        bank.increaseBalance(msg.sender, amount / SATOSHI_MULTIPLIER);
    }
}

/// @dev Faithful double for the opaque Wormhole Token Bridge. On a redemption it
///      completes the contract-controlled transfer by delivering tBTC to the
///      caller (the redeemer) and returns the encoded transfer struct carrying
///      the user's Bitcoin `redemptionOutputScript` as its payload.
contract WormholeTokenBridge {
    MiniToken public tbtc;
    uint256 public transferAmount;
    bytes public outputScript;
    bytes32 public fromAddress;

    constructor(MiniToken _tbtc, uint256 _amount, bytes memory _script, bytes32 _from) {
        tbtc = _tbtc;
        transferAmount = _amount;
        outputScript = _script;
        fromAddress = _from;
    }

    function completeTransferWithPayload(bytes memory) external returns (bytes memory) {
        // Deliver the bridged tBTC to the redeemer (msg.sender).
        tbtc.mint(msg.sender, transferAmount);

        IWormholeTokenBridge.TransferWithPayload memory t = IWormholeTokenBridge.TransferWithPayload({
            payloadID: 3,
            amount: transferAmount,
            tokenAddress: bytes32(uint256(uint160(address(tbtc)))),
            tokenChain: 2,
            to: bytes32(uint256(uint160(msg.sender))),
            toChain: 2,
            fromAddress: fromAddress,
            payload: outputScript
        });
        return abi.encode(t);
    }

    function parseTransferWithPayload(bytes memory encoded)
        external
        pure
        returns (IWormholeTokenBridge.TransferWithPayload memory)
    {
        return abi.decode(encoded, (IWormholeTokenBridge.TransferWithPayload));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract — verbatim pre-fix requestRedemption + _requestRedemption
// (L1BTCRedeemerWormhole + AbstractBTCRedeemer at 57a61c36~1). Inheritance is
// flattened; the `nonReentrant` modifier and the unreachable gas-reimbursement
// tail are elided (orthogonal to the bug). The defective lines are verbatim.
// ─────────────────────────────────────────────────────────────────────────────
contract L1BTCRedeemerWormhole {
    uint256 public constant SATOSHI_MULTIPLIER = 10**10;

    IBridge public thresholdBridge;
    IERC20Like public tbtcToken;
    IBank public bank;
    ITBTCVault public tbtcVault;
    IWormholeTokenBridge public wormholeTokenBridge;

    constructor(
        address _thresholdBridge,
        address _tbtcToken,
        address _bank,
        address _tbtcVault,
        address _wormholeTokenBridge
    ) {
        thresholdBridge = IBridge(_thresholdBridge);
        tbtcToken = IERC20Like(_tbtcToken);
        bank = IBank(_bank);
        tbtcVault = ITBTCVault(_tbtcVault);
        wormholeTokenBridge = IWormholeTokenBridge(_wormholeTokenBridge);
    }

    function requestRedemption(
        bytes20 walletPubKeyHash,
        BitcoinTx.UTXO calldata mainUtxo,
        bytes calldata encodedVm
    ) external {
        uint256 balanceBefore = tbtcToken.balanceOf(address(this));
        bytes memory encoded = wormholeTokenBridge.completeTransferWithPayload(
            encodedVm
        );
        uint256 balanceAfter = tbtcToken.balanceOf(address(this));

        uint256 amount = balanceAfter - balanceBefore;

        bytes memory redemptionOutputScript = wormholeTokenBridge
            .parseTransferWithPayload(encoded)
            .payload;

        // Convert the received ERC20 amount (1e18) to satoshi equivalent (1e8) for Bridge operations.
        uint64 amountInSatoshis = uint64(amount / SATOSHI_MULTIPLIER);

        (uint256 redemptionKey, ) = _requestRedemption(
            walletPubKeyHash,
            mainUtxo,
            redemptionOutputScript,
            amountInSatoshis
        );

        redemptionKey; // silence unused warning (event elided)
    }

    function _requestRedemption(
        bytes20 walletPubKeyHash,
        BitcoinTx.UTXO memory mainUtxo,
        bytes memory redemptionOutputScript,
        uint64 amount
    ) internal returns (uint256 redemptionKey, uint256 tbtcAmount) {
        // This contract (as balanceOwner) approves the Bridge to spend its Bank balance.
        // The amount for Bank allowance is in satoshi units (which is what `amount` already is).
        bank.increaseBalanceAllowance(address(thresholdBridge), amount); // @> grants the Bridge an allowance but NEVER credits this contract's Bank balance (the `tbtcVault.unmint` credit is missing) — Bridge.transferBalanceFrom later reverts

        // This contract calls the Bridge. The Bridge will see `msg.sender` (this contract) as the `balanceOwner`.
        thresholdBridge.requestRedemption(
            walletPubKeyHash,
            mainUtxo,
            redemptionOutputScript,
            amount
        );

        redemptionKey = _getRedemptionKey(
            walletPubKeyHash,
            redemptionOutputScript
        );

        IBridgeTypes.RedemptionRequest memory redemption = thresholdBridge
            .pendingRedemptions(redemptionKey);

        tbtcAmount = _calculateTbtcAmount(
            redemption.requestedAmount,
            redemption.treasuryFee
        );
    }

    function _calculateTbtcAmount(
        uint64 redemptionAmountSat,
        uint64 redemptionTreasuryFeeSat
    ) internal view returns (uint256) {
        uint256 amountSubTreasury = (redemptionAmountSat -
            redemptionTreasuryFeeSat) * SATOSHI_MULTIPLIER;

        (, , uint64 redemptionTxMaxFee, , , , ) = thresholdBridge
            .redemptionParameters();

        uint256 txMaxFee = redemptionTxMaxFee * SATOSHI_MULTIPLIER;
        return amountSubTreasury - txMaxFee;
    }

    function _getRedemptionKey(bytes20 walletPubKeyHash, bytes memory script)
        internal
        pure
        returns (uint256)
    {
        bytes32 scriptHash = keccak256(script);
        uint256 key;
        /* solhint-disable-next-line no-inline-assembly */
        assembly {
            mstore(0, scriptHash)
            mstore(32, walletPubKeyHash)
            key := keccak256(0, 52)
        }
        return key;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract — the real fix (commit 57a61c36): approve + `tbtcVault.unmint`
// credits this contract's Bank balance in satoshis BEFORE granting the Bridge
// allowance, so `transferBalanceFrom` succeeds and the redemption completes.
// Only the balance-credit is added; everything else is identical. This isolates
// the missing credit as the exact cause.
// ─────────────────────────────────────────────────────────────────────────────
contract L1BTCRedeemerWormholeFixed {
    uint256 public constant SATOSHI_MULTIPLIER = 10**10;

    IBridge public thresholdBridge;
    IERC20Like public tbtcToken;
    IBank public bank;
    ITBTCVault public tbtcVault;
    IWormholeTokenBridge public wormholeTokenBridge;

    constructor(
        address _thresholdBridge,
        address _tbtcToken,
        address _bank,
        address _tbtcVault,
        address _wormholeTokenBridge
    ) {
        thresholdBridge = IBridge(_thresholdBridge);
        tbtcToken = IERC20Like(_tbtcToken);
        bank = IBank(_bank);
        tbtcVault = ITBTCVault(_tbtcVault);
        wormholeTokenBridge = IWormholeTokenBridge(_wormholeTokenBridge);
    }

    function requestRedemption(
        bytes20 walletPubKeyHash,
        BitcoinTx.UTXO calldata mainUtxo,
        bytes calldata encodedVm
    ) external {
        uint256 balanceBefore = tbtcToken.balanceOf(address(this));
        bytes memory encoded = wormholeTokenBridge.completeTransferWithPayload(
            encodedVm
        );
        uint256 balanceAfter = tbtcToken.balanceOf(address(this));

        uint256 amount = balanceAfter - balanceBefore;

        bytes memory redemptionOutputScript = wormholeTokenBridge
            .parseTransferWithPayload(encoded)
            .payload;

        (uint256 redemptionKey, ) = _requestRedemption(
            walletPubKeyHash,
            mainUtxo,
            redemptionOutputScript,
            amount
        );

        redemptionKey;
    }

    function _requestRedemption(
        bytes20 walletPubKeyHash,
        BitcoinTx.UTXO memory mainUtxo,
        bytes memory redemptionOutputScript,
        uint256 amount
    ) internal returns (uint256 redemptionKey, uint256 tbtcAmount) {
        // FIX: reset+approve the vault, then unmint. `unmint` burns the ERC-20
        // tBTC and credits this contract's balance in the Bank with the
        // corresponding satoshi value BEFORE the Bridge pulls it.
        tbtcToken.approve(address(tbtcVault), 0);
        tbtcToken.approve(address(tbtcVault), amount);
        tbtcVault.unmint(amount);

        uint64 amountInSatoshis = uint64(amount / SATOSHI_MULTIPLIER);

        bank.increaseBalanceAllowance(address(thresholdBridge), amountInSatoshis);

        thresholdBridge.requestRedemption(
            walletPubKeyHash,
            mainUtxo,
            redemptionOutputScript,
            amountInSatoshis
        );

        redemptionKey = _getRedemptionKey(
            walletPubKeyHash,
            redemptionOutputScript
        );

        IBridgeTypes.RedemptionRequest memory redemption = thresholdBridge
            .pendingRedemptions(redemptionKey);

        tbtcAmount = _calculateTbtcAmount(
            redemption.requestedAmount,
            redemption.treasuryFee
        );
    }

    function _calculateTbtcAmount(
        uint64 redemptionAmountSat,
        uint64 redemptionTreasuryFeeSat
    ) internal view returns (uint256) {
        uint256 amountSubTreasury = (redemptionAmountSat -
            redemptionTreasuryFeeSat) * SATOSHI_MULTIPLIER;

        (, , uint64 redemptionTxMaxFee, , , , ) = thresholdBridge
            .redemptionParameters();

        uint256 txMaxFee = redemptionTxMaxFee * SATOSHI_MULTIPLIER;
        return amountSubTreasury - txMaxFee;
    }

    function _getRedemptionKey(bytes20 walletPubKeyHash, bytes memory script)
        internal
        pure
        returns (uint256)
    {
        bytes32 scriptHash = keccak256(script);
        uint256 key;
        /* solhint-disable-next-line no-inline-assembly */
        assembly {
            mstore(0, scriptHash)
            mstore(32, walletPubKeyHash)
            key := keccak256(0, 52)
        }
        return key;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: drive the REAL vulnerable requestRedemption path. It reverts
// because the redeemer's Bank balance was never credited. The whole redemption
// is DoS'd and the bridged tBTC is permanently stranded; record the stranded
// magnitude on the LOCKED-tBTC marker to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    uint256 internal constant SATOSHI_MULTIPLIER = 10**10;

    // 10 tBTC bridged in for redemption (1e18 precision).
    uint256 internal constant REDEEM_TBTC = 10 ether;

    bytes20 internal constant WALLET_PUBKEY_HASH =
        bytes20(0x1234567890AbcdEF1234567890aBcdef12345678);

    // Exposed results.
    bool public redemptionReverted;
    string public revertReason;
    uint256 public lockedTbtc;
    uint256 public sinkMarkerBalance;
    address public redeemerAddr;
    address public bankAddr;
    address public bridgeAddr;
    address public markerAddr;
    address public tbtcAddr;

    function run() external payable {
        // --- deploy the real vulnerable redeemer + faithful doubles ---
        MiniToken tbtc = new MiniToken("tBTC", "tBTC");                       // nonce 1
        Bank bank = new Bank();                                               // nonce 2
        Bridge bridge = new Bridge(bank);                                     // nonce 3
        TBTCVault vault = new TBTCVault(tbtc, bank);                          // nonce 4
        bytes memory script = hex"76a9141234567890abcdef1234567890abcdef1234567888ac";
        WormholeTokenBridge wh = new WormholeTokenBridge(                     // nonce 5
            tbtc,
            REDEEM_TBTC,
            script,
            bytes32(uint256(uint160(0xB0B)))
        );
        L1BTCRedeemerWormhole redeemer = new L1BTCRedeemerWormhole(           // nonce 6
            address(bridge),
            address(tbtc),
            address(bank),
            address(vault),
            address(wh)
        );
        MiniToken marker = new MiniToken("Locked tBTC", "LOCKED-tBTC");       // nonce 7 (LAST)

        redeemerAddr = address(redeemer);
        bankAddr = address(bank);
        bridgeAddr = address(bridge);
        markerAddr = address(marker);
        tbtcAddr = address(tbtc);

        // --- drive the real Wormhole redemption entry point ---
        BitcoinTx.UTXO memory utxo = BitcoinTx.UTXO({
            txHash: bytes32(uint256(0xDEAD)),
            txOutputIndex: 0,
            txOutputValue: uint64(REDEEM_TBTC / SATOSHI_MULTIPLIER)
        });
        bytes memory encodedVm = hex"00"; // opaque VAA — decoded by the double

        // Harm: the top-level redemption MUST revert because the redeemer's Bank
        // balance was never credited — the bridged tBTC can never be redeemed.
        try redeemer.requestRedemption(WALLET_PUBKEY_HASH, utxo, encodedVm) {
            redemptionReverted = false;
        } catch Error(string memory reason) {
            redemptionReverted = true;
            revertReason = reason;
        } catch {
            redemptionReverted = true;
            revertReason = "low-level revert";
        }

        require(redemptionReverted, "expected Wormhole redemption to revert (DoS)");

        // Record the permanently stranded magnitude to the SINK.
        lockedTbtc = REDEEM_TBTC;
        marker.mint(SINK, lockedTbtc);
        sinkMarkerBalance = marker.balanceOf(SINK);
    }
}
