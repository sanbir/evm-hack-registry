// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tapioca BaseLeverageExecutor — WETH.withdraw reverts (Pashov 2024-02, H-02).
    SYNTHETIC, cheatcode-free. The audited _handleToftWrapToSender is copied
    below. weth.withdraw sends ETH to the executor. There is no receive(), so
    the send reverts and the ETH stays in WETH. The fix is receive(). */

interface ITOFT {
    function erc20() external view returns (address);
    function wrap(address from, address to, uint256 amount) external payable;
}

interface IERC20Approve {
    function safeApprove(address spender, uint256 amount) external;
}

contract WETH9 {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "WETH: burn");
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
    }
}

contract EthTOFT {
    function erc20() external pure returns (address) {
        return address(0);
    }

    function wrap(address, address to, uint256 amount) external payable {
        require(msg.value == amount, "TOFT: value");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "TOFT: forward");
    }
}

contract BaseLeverageExecutor {
    WETH9 public weth;

    constructor(WETH9 _weth) {
        weth = _weth;
    }

    /// Swap output left N WETH on this contract. Deposit is the stand-in for that swap.
    function fund() external payable {
        weth.deposit{value: msg.value}();
    }

    function getAsset(address tokenOut, uint256 amountOut) external {
        _handleToftWrapToSender(true, tokenOut, amountOut);
    }

    function _handleToftWrapToSender(bool sendBack, address tokenOut, uint256 amountOut) internal {
        address toftErc20 = ITOFT(tokenOut).erc20();
        address wrapsTo = sendBack == true ? msg.sender : address(this);

        if (toftErc20 == address(0)) {
            // If the tOFT is for ETH, withdraw from WETH and wrap it.
            // @> VULN: weth.withdraw sends ETH here, and this contract has no receive()
            weth.withdraw(amountOut);
            ITOFT(tokenOut).wrap{value: amountOut}(address(this), wrapsTo, amountOut);
        } else {
            IERC20Approve(toftErc20).safeApprove(tokenOut, amountOut);
            ITOFT(tokenOut).wrap(address(this), wrapsTo, amountOut);
            IERC20Approve(toftErc20).safeApprove(tokenOut, 0);
        }
    }
}

/// Same executor plus the recommended receive(). withdraw can deliver the ETH.
contract BaseLeverageExecutorFixed is BaseLeverageExecutor {
    constructor(WETH9 _weth) BaseLeverageExecutor(_weth) {}

    receive() external payable {}
}

contract Exploit {
    uint256 public constant AMOUNT = 1 ether;

    WETH9 public weth; // CREATE nonce 1
    EthTOFT public toft; // CREATE nonce 2
    BaseLeverageExecutor public executor; // CREATE nonce 3

    uint256 public stuckInWeth;
    uint256 public userReceived;
    bool public unwrapReverted;

    constructor() {
        weth = new WETH9();
        toft = new EthTOFT();
        executor = new BaseLeverageExecutor(weth);
    }

    function run() external payable {
        require(msg.value == AMOUNT, "value");
        executor.fund{value: msg.value}();
        stuckInWeth = address(weth).balance;
        require(stuckInWeth == AMOUNT, "WETH was not funded");
        require(weth.balanceOf(address(executor)) == AMOUNT, "executor missing WETH");
        (bool ok,) = address(executor).call(
            abi.encodeWithSelector(executor.getAsset.selector, address(toft), AMOUNT)
        );
        unwrapReverted = !ok;
        require(unwrapReverted, "unwrap must revert");
        require(address(weth).balance == AMOUNT, "ETH left WETH");
        require(weth.balanceOf(address(executor)) == AMOUNT, "WETH was burned");
        userReceived = address(this).balance;
        require(userReceived == 0, "user was paid");
    }
}
