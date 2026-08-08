// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

library Transfers {
    function safeTransfer(address token, address to, uint256 value) internal {
        // @> A call to a non-existent token returns success without moving tokens.
        (bool success, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer fail");
    }
    function safeTransferFrom(address token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom fail");
    }
}

contract Pool {
    using Transfers for address;
    function swap(address tokenIn, address tokenOut, uint256 amount) external {
        tokenIn.safeTransferFrom(msg.sender, address(this), amount);
        tokenOut.safeTransfer(msg.sender, amount);
    }
}

contract Exploit {
    event Proof(uint256 inputInPool, uint256 outputReceived);
    function run() external {
        MockToken input = new MockToken();
        Pool pool = new Pool();
        input.mint(address(this), 1000);
        pool.swap(address(input), address(0xBEEF), 1000);
        emit Proof(input.balanceOf(address(pool)), 0);
        require(input.balanceOf(address(pool)) == 1000, "input was not lost");
    }
}
