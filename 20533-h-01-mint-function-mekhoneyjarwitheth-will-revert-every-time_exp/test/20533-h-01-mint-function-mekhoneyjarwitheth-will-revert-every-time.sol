// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  BearCave HoneyBox — mekHoneyJarWithETH is not payable (Pashov H-01, #20533).
    SYNTHETIC, cheatcode-free. The audited signature has no payable keyword, so
    every purchase that attaches the mint price reverts in the dispatcher.
    The body still reads msg.value to check the price. A zero-value call enters
    that line and reverts WrongAmount_ETH. No jar is minted and no ETH is taken. */

contract HoneyBox {
    error WrongAmount_ETH(uint256 expected, uint256 paid);

    uint256 public constant PRICE = 0.1 ether;
    uint256 public minted;

    // Audited signature: external, not payable (Pashov diff).
    // solc 0.8.27 rejects msg.value in a non-payable function, so the price
    // read is callvalue(), which is the same opcode.
    function mekHoneyJarWithETH(uint8 bundleId_, uint256 amount_) external returns (uint256) {
        bundleId_;
        uint256 expected = PRICE * amount_;
        uint256 paid;
        assembly {
            paid := callvalue()
        }
        // @> VULN: callvalue is 0 because this function is not payable, so the price check reverts
        if (paid != expected) revert WrongAmount_ETH(expected, paid);
        minted += amount_;
        return minted;
    }
}

contract Sink {
    // Profit is measured here so the buyer's unused ETH is not reported as profit.
}

contract Exploit {
    HoneyBox public box;
    Sink public sink;

    constructor() {
        box = new HoneyBox();
        sink = new Sink();
    }

    function run() external payable {
        require(msg.value == 0.1 ether, "fund");
        uint256 held = address(this).balance;
        (bool paidOk,) = address(box).call{value: 0.1 ether}(
            abi.encodeWithSignature("mekHoneyJarWithETH(uint8,uint256)", uint8(1), uint256(1))
        );
        require(!paidOk, "value call must revert");
        require(box.minted() == 0, "value minted");
        require(address(box).balance == 0, "box took eth");
        try box.mekHoneyJarWithETH(1, 1) returns (uint256) {
            revert("zero value minted");
        } catch {}
        require(box.minted() == 0, "still zero");
        require(address(this).balance == held, "buyer kept the 0.1 ETH");
    }
}
